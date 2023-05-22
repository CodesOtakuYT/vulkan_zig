const std = @import("std");
const builtin = @import("builtin");
const c = @import("c.zig");

fn GetFunctionPointer(comptime name: []const u8) type {
    return std.meta.Child(@field(c, "PFN_" ++ name));
}

fn lookup(library: *std.DynLib, comptime name: [:0]const u8) GetFunctionPointer(name) {
    return library.lookup(GetFunctionPointer(name), name).?;
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
        const get_instance_proc_addr = lookup(&library, "vkGetInstanceProcAddr");
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

const QueueFamily = struct {
    physical_device: c.VkPhysicalDevice,
    queue_family_index: u32,
};

const Device = struct {
    const Self = @This();
    handle: c.VkDevice,
    allocation_callbacks: ?*c.VkAllocationCallbacks,
    destroy_device: std.meta.Child(c.PFN_vkDestroyDevice),

    fn init(instance: Instance, queue_family: QueueFamily, allocation_callbacks: ?*c.VkAllocationCallbacks) !Device {
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

const Context = struct {
    const Self = @This();

    entry: Entry,
    instance: Instance,
    device: Device,

    fn init(allocator: std.mem.Allocator) !Self {
        var entry = try Entry.init();
        const instance = try Instance.init(entry, null);
        const physical_devices = try instance.get_physical_devices(allocator);
        defer allocator.free(physical_devices);
        const queue_family = (try instance.select_queue_family(physical_devices, allocator, c.VK_QUEUE_COMPUTE_BIT)).?;
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

pub fn main() !void {
    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = general_purpose_allocator.allocator();

    var context = try Context.init(allocator);
    defer context.deinit();
}
