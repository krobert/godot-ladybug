# Godot LadybugDB Extension

A C++ GDExtension integrating LadybugDB into Godot, packaged with GDScript helper utilities as a single addon.

## Repository Structure

* `src/` - Custom C++ source code.
* `godot-cpp/` - Official Godot C++ bindings (submodule).
* `thirdparty/` - Precompiled LadybugDB libraries.
* `demo/` - Godot test project.
  * `demo/addons/` - The complete plugin containing GDScripts, the `.gdextension` manifest, and the compiled `bin/` binaries.

## Building from Source

**Requirements:**
* Python 3.x & SCons
* A C++ compiler (GCC, Clang, or MSVC)

1. Clone the repository with submodules:
    ```bash
    git clone --recurse-submodules [https://github.com/krobert/godot-ladybug.git](https://github.com/krobert/godot-ladybug.git)
    cd YOUR_REPO
    ```

2. Compile the C++ bindings and the extension for your platform:
    ```bash
    scons platform=windows
    # Or platform=linux, platform=macos || platform=macos arch=arm64
    ```
    
    You dont need mcp? add this param
    `build_mcp=no`
    you only want mcp?
    `build_ladybug=no`
    *Compiled libraries will be automatically placed inside `demo/addons/ladybug/bin` and mcp/bin.*

## Installation

To use this extension in your own Godot project:

1. Download the compiled release.
2. Extract and copy the release compiled folder and the `addons` folder content into your Godot project's `addons/` directory.

## Usage

Once installed, the C++ nodes are available in your project, and you can utilize the helper scripts immediately.

```gdscript
extends Node

@export var schema: LadybugSchema = ExampleSchema.new()

func _ready():
  LadybugBridge.set_log_level(LadybugBridge.LogLevel.ALL)
  LadybugBridge.database_ready.connect(_on_db_ready)
  await LadybugBridge.init_db(schema, "people.lbdb")
  
func _on_db_ready():
  print("db_ready")
  var result = LadybugBridge.read_query("MATCH (p:Person) RETURN p.name, p.age")
  for row in result:
    print("Name: ", row["p.name"], " Age: ", row["p.age"])

  LadybugBridge.write_query("CREATE (:Person {name: $n})", {"n": "Charlie"}, func(res, err):
    if err != "":
      print("Write failed: ", err)
    else:
      print("Write succeeded")
  )
  
func _exit_tree() -> void:
  LadybugBridge.close_db()

```

## Support this project

[![Buy Me A Coffee](https://img.shields.io/badge/Buy_Me_A_Coffee-FFDD00?style=for-the-badge&logo=buy-me-a-coffee&logoColor=black)](https://buymeacoffee.com/krobert)


<details>
<summary><b>Direct Crypto Wallet Addresses</b></summary>

* **BTC (SEGWIT):** `bc1qp69su3jeztapz8v9j67xman0kjru37tkd34rv0`
* **ETH (ERC20):** `0xf43c044b08e3889692c6990f59614597573f72b3`
* **SOL:** `FdE7AH4i8WTVgiCdfWXgnMYu8896fK11qLHckamxHF7v`
</details>