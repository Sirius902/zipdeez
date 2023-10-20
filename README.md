# zipdeez ['zɪpdi 'izi]

A [Zig](https://ziglang.org/) library for manipulating Zip archives.

**Note:** This library is a work in progress and is intended for use with Zig `master`.

## Usage

* Create a `build.zig.zon` in your project like the example below, replacing
`LATEST_COMMIT` with the latest commit hash.

```zig
.{
    .name = "myproject",
    .version = "0.1.0",
    .dependencies = .{
        .zipdeez = .{
            .url = "git+https://github.com/Sirius902/zipdeez.git#LATEST_COMMIT,
        },
    },
    .paths = .{
        "src",
        "build.zig",
        "build.zig.zon",
    },
}
```

* Run `zig build` and add the displayed `.hash` to the `.zipdeez` dependency as instructed.
* Add the `zipdeez` module to your program in `build.zig`.

```zig
exe.addModule("zipdeez", b.dependency("zipdeez", .{
    .target = target,
    .optimize = optimize,
}).module("zipdeez"));
```
