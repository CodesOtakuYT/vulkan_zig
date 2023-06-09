const std = @import("std");
const builtin = @import("builtin");
const c = @import("c.zig");
const shader = @embedFile("res/shaders/simple.comp.spv");

fn GetFunctionPointer(comptime name: []const u8) type {
    return std.meta.Child(@field(c, "PFN_" ++ name));
}

fn lookup(library: *std.DynLib, comptime name: [:0]const u8) !GetFunctionPointer(name) {
    return library.lookup(GetFunctionPointer(name), name) orelse error.SymbolNotFound;
}

fn load(comptime name: []const u8, proc_addr: anytype, handle: anytype) GetFunctionPointer(name) {
    return @ptrCast(GetFunctionPointer(name), proc_addr(handle, name.ptr));
}

fn load_library(library_names: []const []const u8) !std.DynLib {
    for (library_names) |library_name| {
        return std.DynLib.open(library_name) catch continue;
    }
    return error.NotFound;
}

const Entry = struct {
    const Self = @This();
    const LibraryNames = switch (builtin.os.tag) {
        .windows => &[_][]const u8{"vulkan-1.dll"},
        .ios, .macos, .tvos, .watchos => &[_][]const u8{ "libvulkan.dylib", "libvulkan.1.dylib", "libMoltenVK.dylib" },
        else => &[_][]const u8{ "libvulkan.so.1", "libvulkan.so" },
    };

    handle: std.DynLib,
    get_instance_proc_addr: std.meta.Child(c.PFN_vkGetInstanceProcAddr),
    create_instance: std.meta.Child(c.PFN_vkCreateInstance),

    fn init() !Self {
        var library = try load_library(LibraryNames);
        const get_instance_proc_addr = try lookup(&library, "vkGetInstanceProcAddr");
        const create_instance = load("vkCreateInstance", get_instance_proc_addr, null);
        return .{
            .handle = library,
            .get_instance_proc_addr = get_instance_proc_addr,
            .create_instance = create_instance,
        };
    }

    fn deinit(self: *Self) void {
        self.handle.close();
    }
};

const Instance = struct {
    const Self = @This();

    handle: c.VkInstance,
    allocation_callbacks: ?*c.VkAllocationCallbacks,
    destroy_instance: std.meta.Child(c.PFN_vkDestroyInstance),
    enumerate_physical_devices: std.meta.Child(c.PFN_vkEnumeratePhysicalDevices),
    get_physical_device_queue_family_properties: std.meta.Child(c.PFN_vkGetPhysicalDeviceQueueFamilyProperties),
    create_device: std.meta.Child(c.PFN_vkCreateDevice),
    get_device_proc_addr: std.meta.Child(c.PFN_vkGetDeviceProcAddr),
    get_physical_device_properties: std.meta.Child(c.PFN_vkGetPhysicalDeviceProperties),

    fn init(entry: Entry, allocation_callbacks: ?*c.VkAllocationCallbacks) !Self {
        const extensions = [_][*:0]const u8{c.VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME};
        const info = std.mem.zeroInit(c.VkInstanceCreateInfo, .{
            .sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .flags = c.VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR,
            .enabledExtensionCount = extensions.len,
            .ppEnabledExtensionNames = &extensions,
        });
        var instance: c.VkInstance = undefined;
        return switch (entry.create_instance(&info, allocation_callbacks, &instance)) {
            c.VK_SUCCESS => .{
                .handle = instance,
                .allocation_callbacks = allocation_callbacks,
                .destroy_instance = load("vkDestroyInstance", entry.get_instance_proc_addr, instance),
                .enumerate_physical_devices = load("vkEnumeratePhysicalDevices", entry.get_instance_proc_addr, instance),
                .get_physical_device_queue_family_properties = load("vkGetPhysicalDeviceQueueFamilyProperties", entry.get_instance_proc_addr, instance),
                .create_device = load("vkCreateDevice", entry.get_instance_proc_addr, instance),
                .get_device_proc_addr = load("vkGetDeviceProcAddr", entry.get_instance_proc_addr, instance),
                .get_physical_device_properties = load("vkGetPhysicalDeviceProperties", entry.get_instance_proc_addr, instance),
            },
            c.VK_ERROR_OUT_OF_HOST_MEMORY => error.OutOfHostMemory,
            c.VK_ERROR_OUT_OF_DEVICE_MEMORY => error.OutOfDeviceMemory,
            c.VK_ERROR_INITIALIZATION_FAILED => error.InitializationFailed,
            c.VK_ERROR_LAYER_NOT_PRESENT => error.LayerNotPresent,
            c.VK_ERROR_EXTENSION_NOT_PRESENT => error.ExtensionNotPresent,
            c.VK_ERROR_INCOMPATIBLE_DRIVER => error.IncompatibleDriver,
            else => unreachable,
        };
    }

    fn deinit(self: Self) void {
        self.destroy_instance(
            self.handle,
            self.allocation_callbacks,
        );
    }

    fn get_physical_devices(self: Self, allocator: std.mem.Allocator) ![]c.VkPhysicalDevice {
        var count: u32 = undefined;

        try switch (self.enumerate_physical_devices(self.handle, &count, null)) {
            c.VK_SUCCESS, c.VK_INCOMPLETE => {},
            c.VK_ERROR_OUT_OF_HOST_MEMORY => error.OutOfHostMemory,
            c.VK_ERROR_INITIALIZATION_FAILED => error.InitializationFailed,
            else => unreachable,
        };
        var physical_devices = try allocator.alloc(c.VkPhysicalDevice, count);
        return switch (self.enumerate_physical_devices(self.handle, &count, physical_devices.ptr)) {
            c.VK_SUCCESS, c.VK_INCOMPLETE => physical_devices,
            c.VK_ERROR_OUT_OF_HOST_MEMORY => error.OutOfHostMemory,
            c.VK_ERROR_INITIALIZATION_FAILED => error.InitializationFailed,
            else => unreachable,
        };
    }

    fn select_queue_family(self: Self, physical_devices: []c.VkPhysicalDevice, allocator: std.mem.Allocator, queue_flags: u32) !?QueueFamily {
        for (physical_devices) |physical_device| {
            var count: u32 = undefined;

            self.get_physical_device_queue_family_properties(physical_device, &count, null);
            var queue_family_properties = try allocator.alloc(c.VkQueueFamilyProperties, count);
            self.get_physical_device_queue_family_properties(physical_device, &count, queue_family_properties.ptr);
            defer allocator.free(queue_family_properties);
            for (queue_family_properties, 0..) |queue_family_property, queue_family_index| {
                if (queue_family_property.queueFlags & queue_flags == queue_flags) {
                    return .{
                        .physical_device = physical_device,
                        .queue_family_index = @intCast(u32, queue_family_index),
                    };
                }
            }
        }

        return null;
    }
};

const PhysicalDeviceType = enum(u32) {
    other,
    integrated_gpu,
    discrete_gpu,
    virtual_gpu,
    cpu,

    fn init(number: u32) @This() {
        return @intToEnum(@This(), number);
    }

    fn name(self: @This()) [:0]const u8 {
        return @tagName(self);
    }
};

const PhysicalDevicePropertiesIterator = struct {
    const Self = @This();

    index: usize = 0,
    physical_devices: []const c.VkPhysicalDevice,
    instance: Instance,

    fn init(instance: Instance, physical_devices: []const c.VkPhysicalDevice) !Self {
        return .{
            .physical_devices = physical_devices,
            .instance = instance,
        };
    }

    fn next(self: *Self) ?c.VkPhysicalDeviceProperties {
        if (self.index >= self.physical_devices.len)
            return null;
        defer self.index += 1;
        var physical_properties: c.VkPhysicalDeviceProperties = undefined;
        self.instance.get_physical_device_properties(self.physical_devices[self.index], &physical_properties);
        return physical_properties;
    }

    fn dump(self: *Self, writer: anytype) !void {
        while (self.next()) |physical_device_properties| {
            const device_type = PhysicalDeviceType.init(physical_device_properties.deviceType).name();
            const device_name = physical_device_properties.deviceName;
            const driver_version = physical_device_properties.driverVersion;

            try writer.print("----- Device {} -----\n", .{self.index});
            try writer.print("Name:           {s}\n", .{device_name});
            try writer.print("Type:           {s}\n", .{device_type});
            try writer.print("Driver Version: {}\n", .{driver_version});
        }
    }
};

const QueueFamily = struct {
    physical_device: c.VkPhysicalDevice,
    queue_family_index: u32,
};

const Device = struct {
    const Self = @This();
    handle: c.VkDevice,
    allocation_callbacks: ?*c.VkAllocationCallbacks,
    destroy_device: std.meta.Child(c.PFN_vkDestroyDevice),

    create_shader_module: std.meta.Child(c.PFN_vkCreateShaderModule),
    destroy_shader_module: std.meta.Child(c.PFN_vkDestroyShaderModule),

    create_pipeline_layout: std.meta.Child(c.PFN_vkCreatePipelineLayout),
    destroy_pipeline_layout: std.meta.Child(c.PFN_vkDestroyPipelineLayout),

    create_pipeline_cache: std.meta.Child(c.PFN_vkCreatePipelineCache),
    destroy_pipeline_cache: std.meta.Child(c.PFN_vkDestroyPipelineCache),
    get_pipeline_cache_data: std.meta.Child(c.PFN_vkGetPipelineCacheData),

    create_compute_pipelines: std.meta.Child(c.PFN_vkCreateComputePipelines),
    destroy_pipeline: std.meta.Child(c.PFN_vkDestroyPipeline),

    fn init(instance: Instance, queue_family: QueueFamily, allocation_callbacks: ?*c.VkAllocationCallbacks) !Self {
        const queue_priorities = [_]f32{1.0};
        const queue_create_infos = [_]c.VkDeviceQueueCreateInfo{.{
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .queueFamilyIndex = queue_family.queue_family_index,
            .queueCount = queue_priorities.len,
            .pQueuePriorities = &queue_priorities,
        }};

        const info = std.mem.zeroInit(c.VkDeviceCreateInfo, .{
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .queueCreateInfoCount = queue_create_infos.len,
            .pQueueCreateInfos = &queue_create_infos,
        });
        var device: c.VkDevice = undefined;
        return switch (instance.create_device(queue_family.physical_device, &info, allocation_callbacks, &device)) {
            c.VK_SUCCESS => .{
                .handle = device,
                .allocation_callbacks = allocation_callbacks,
                .destroy_device = load("vkDestroyDevice", instance.get_device_proc_addr, device),
                .create_shader_module = load("vkCreateShaderModule", instance.get_device_proc_addr, device),
                .destroy_shader_module = load("vkDestroyShaderModule", instance.get_device_proc_addr, device),
                .create_pipeline_layout = load("vkCreatePipelineLayout", instance.get_device_proc_addr, device),
                .destroy_pipeline_layout = load("vkDestroyPipelineLayout", instance.get_device_proc_addr, device),
                .create_pipeline_cache = load("vkCreatePipelineCache", instance.get_device_proc_addr, device),
                .destroy_pipeline_cache = load("vkDestroyPipelineCache", instance.get_device_proc_addr, device),
                .get_pipeline_cache_data = load("vkGetPipelineCacheData", instance.get_device_proc_addr, device),
                .create_compute_pipelines = load("vkCreateComputePipelines", instance.get_device_proc_addr, device),
                .destroy_pipeline = load("vkDestroyPipeline", instance.get_device_proc_addr, device),
            },
            c.VK_ERROR_OUT_OF_HOST_MEMORY => error.OutOfHostMemory,
            c.VK_ERROR_OUT_OF_DEVICE_MEMORY => error.OutOfDeviceMemory,
            c.VK_ERROR_INITIALIZATION_FAILED => error.InitializationFailed,
            c.VK_ERROR_EXTENSION_NOT_PRESENT => error.ExtensionNotPresent,
            c.VK_ERROR_FEATURE_NOT_PRESENT => error.FeatureNotPresent,
            c.VK_ERROR_TOO_MANY_OBJECTS => error.TooManyObjects,
            c.VK_ERROR_DEVICE_LOST => error.DeviceLost,
            else => unreachable,
        };
    }

    fn deinit(self: Self) void {
        self.destroy_device(self.handle, self.allocation_callbacks);
    }
};

fn Context(comptime max_stack_physical_devices: usize, comptime max_stack_queue_families: usize) type {
    return struct {
        const Self = @This();

        entry: Entry,
        instance: Instance,
        device: Device,

        fn init(allocator: std.mem.Allocator) !Self {
            var entry = try Entry.init();
            const instance = try Instance.init(entry, null);

            var phyical_devices_stack_fallback = std.heap.stackFallback(max_stack_physical_devices * @sizeOf(c.VkPhysicalDevice), allocator);
            const phyical_devices_stack_fallback_allocator = phyical_devices_stack_fallback.get();
            const physical_devices = try instance.get_physical_devices(phyical_devices_stack_fallback_allocator);
            defer phyical_devices_stack_fallback_allocator.free(physical_devices);

            var queue_family_properties_stack_fallback = std.heap.stackFallback(max_stack_queue_families * @sizeOf(c.VkQueueFamilyProperties), allocator);
            const queue_family_properties_stack_fallback_allocator = queue_family_properties_stack_fallback.get();
            const queue_family = (try instance.select_queue_family(physical_devices, queue_family_properties_stack_fallback_allocator, c.VK_QUEUE_COMPUTE_BIT)) orelse return error.NoSuitableQueueFamily;

            const device = try Device.init(instance, queue_family, null);
            return .{
                .entry = entry,
                .instance = instance,
                .device = device,
            };
        }

        fn deinit(self: *Self) void {
            self.device.deinit();
            self.instance.deinit();
            self.entry.deinit();
        }
    };
}

const ShaderModule = struct {
    const Self = @This();

    device: Device,
    allocation_callbacks: ?*c.VkAllocationCallbacks,

    handle: c.VkShaderModule,

    fn init(device: Device, allocation_callbacks: ?*c.VkAllocationCallbacks, code: []const u8) !Self {
        // TODO: isAligned or isAlignedLog2?
        if (!std.mem.isAligned(@ptrToInt(code.ptr), 4)) return error.BadAlignment;
        const info = c.VkShaderModuleCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .codeSize = code.len,
            .pCode = @ptrCast([*c]const u32, @alignCast(4, shader)),
        };
        var module: c.VkShaderModule = undefined;
        return switch (device.create_shader_module(device.handle, &info, allocation_callbacks, &module)) {
            c.VK_SUCCESS => .{
                .device = device,
                .handle = module,
                .allocation_callbacks = allocation_callbacks,
            },
            c.VK_ERROR_OUT_OF_HOST_MEMORY => error.OutOfHostMemory,
            c.VK_ERROR_OUT_OF_DEVICE_MEMORY => error.OutOfDeviceMemory,
            c.VK_ERROR_INVALID_SHADER_NV => error.InvalidShader,
            else => unreachable,
        };
    }

    fn deinit(self: Self) void {
        self.device.destroy_shader_module(self.device.handle, self.handle, self.allocation_callbacks);
    }
};

const PipelineLayout = struct {
    const Self = @This();

    device: Device,
    allocation_callbacks: ?*c.VkAllocationCallbacks,

    handle: c.VkPipelineLayout,

    fn init(device: Device, allocation_callbacks: ?*c.VkAllocationCallbacks) !Self {
        const info = std.mem.zeroInit(c.VkPipelineLayoutCreateInfo, .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        });
        var pipeline_layout: c.VkPipelineLayout = undefined;
        return switch (device.create_pipeline_layout(device.handle, &info, allocation_callbacks, &pipeline_layout)) {
            c.VK_SUCCESS => .{
                .device = device,
                .allocation_callbacks = allocation_callbacks,
                .handle = pipeline_layout,
            },
            c.VK_ERROR_OUT_OF_HOST_MEMORY => error.OutOfHostMemory,
            c.VK_ERROR_OUT_OF_DEVICE_MEMORY => error.OutOfDeviceMemory,
            else => unreachable,
        };
    }

    fn deinit(self: Self) void {
        self.device.destroy_pipeline_layout(self.device.handle, self.handle, self.allocation_callbacks);
    }
};

const ComputePipelines = struct {
    const Self = @This();

    device: Device,
    allocation_callbacks: ?*c.VkAllocationCallbacks,
    allocator: std.mem.Allocator,

    handles: []c.VkPipeline,

    fn init(device: Device, infos: []const c.VkComputePipelineCreateInfo, allocator: std.mem.Allocator, allocation_callbacks: ?*c.VkAllocationCallbacks) !ComputePipelines {
        var pipelines = try allocator.alloc(c.VkPipeline, infos.len);
        return switch (device.create_compute_pipelines(device.handle, null, @intCast(u32, infos.len), infos.ptr, allocation_callbacks, pipelines.ptr)) {
            c.VK_SUCCESS => .{
                .device = device,
                .allocation_callbacks = allocation_callbacks,
                .allocator = allocator,
                .handles = pipelines,
            },
            else => unreachable,
        };
    }

    fn deinit(self: Self) void {
        for (self.handles) |handle| self.device.destroy_pipeline(self.device.handle, handle, self.allocation_callbacks);
        self.allocator.free(self.handles);
    }
};

const PipelineCache = struct {
    const Self = @This();

    device: Device,
    allocation_callbacks: ?*c.VkAllocationCallbacks,

    handle: c.VkPipelineCache,

    fn init(device: Device, data: []u8, allocation_callbacks: ?*c.VkAllocationCallbacks) !Self {
        const info = c.VkPipelineCacheCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_CACHE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .initialDataSize = data.len,
            .pInitialData = data.ptr,
        };
        var pipeline_cache: c.VkPipelineCache = undefined;
        return switch (device.create_pipeline_cache(device.handle, &info, allocation_callbacks, &pipeline_cache)) {
            c.VK_SUCCESS => .{
                .device = device,
                .allocation_callbacks = allocation_callbacks,
                .handle = pipeline_cache,
            },
            else => unreachable,
        };
    }

    fn deinit(self: Self) void {
        self.device.destroy_pipeline_cache(self.device.handle, self.handle, self.allocation_callbacks);
    }

    fn get_data(self: Self, allocator: std.mem.Allocator) ![]u8 {
        var size: usize = undefined;
        try switch (self.device.get_pipeline_cache_data(self.device.handle, self.handle, &size, null)) {
            c.VK_SUCCESS => {},
            c.VK_ERROR_OUT_OF_HOST_MEMORY => error.OutOfHostMemory,
            else => unreachable,
        };
        const data = try allocator.alloc(u8, size);
        return switch (self.device.get_pipeline_cache_data(self.device.handle, self.handle, &size, data.ptr)) {
            c.VK_SUCCESS => data,
            else => unreachable,
        };
    }
};

fn read_file_contents(sub_path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const file = try std.fs.cwd().openFile(sub_path, .{});
    defer file.close();
    const metadata = try file.metadata();
    if (metadata.kind() == .File) {
        return file.readToEndAlloc(allocator, std.math.maxInt(usize));
    } else {
        return error.WrongFileType;
    }
}

fn write_file_contents(sub_path: []const u8, data: []u8) !void {
    const file = try std.fs.cwd().createFile(sub_path, .{});
    defer file.close();
    try file.writeAll(data);
}

pub fn main() !void {
    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{
        .verbose_log = true,
    }){};
    defer std.debug.assert(general_purpose_allocator.deinit() == .ok);
    const allocator = general_purpose_allocator.allocator();

    var context = try Context(4, 8).init(allocator);
    defer context.deinit();

    const pipeline_layout = try PipelineLayout.init(context.device, null);
    defer pipeline_layout.deinit();

    const shader_module = try ShaderModule.init(context.device, null, shader[0..]);
    defer shader_module.deinit();

    const shader_stages = [_]c.VkPipelineShaderStageCreateInfo{.{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .stage = c.VK_SHADER_STAGE_COMPUTE_BIT,
        .module = shader_module.handle,
        .pName = "main",
        .pSpecializationInfo = null,
    }};

    const infos = [_]c.VkComputePipelineCreateInfo{.{
        .sType = c.VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .stage = shader_stages[0],
        .layout = pipeline_layout.handle,
        .basePipelineHandle = null,
        .basePipelineIndex = 0,
    }};

    var data: []u8 = read_file_contents("pipeline_cache.bin", allocator) catch &.{};
    defer if (data.len > 0) allocator.free(data);

    const pipeline_cache = try PipelineCache.init(context.device, data, null);
    defer {
        if (pipeline_cache.get_data(allocator)) |bytes| {
            write_file_contents("pipeline_cache.bin", bytes) catch {};
            allocator.free(bytes);
        } else |_| {}
        pipeline_cache.deinit();
    }

    const compute_pipelines = try ComputePipelines.init(context.device, infos[0..], allocator, null);
    defer compute_pipelines.deinit();
}
