Vulkan application made using the zig programming language
Being made in a livestream:
https://youtu.be/Kf7BIPUUfsc
## Build Instructions
```sh
zig run prebuild.zig -- translate_cimports compile_shaders
zig build run
```
You can also clean the generated files:
```sh
zig run prebuild.zig -- clean
```
