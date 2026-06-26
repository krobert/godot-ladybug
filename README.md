# Godot LadybugDB + MCP Server Extensions

A C++ GDExtension integrating LadybugDB into Godot, packaged with GDScript helper utilities as a single addon.
You can read / write your game database from AI agents. (Tested with hermes, odysseus)

I also added `Glaze` for json parsing and schema validation. 

For best performance make your graph models in cpp struct and compile your own version.

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
    git clone --no-recurse-submodules https://github.com/krobert/godot-ladybug.git
    cd godot-ladybug

    git submodule sync --recursive
    git submodule update --init --recursive
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
3. Check the demo project to see how to use it


## Support this project

[![Buy Me A Coffee](https://img.shields.io/badge/Buy_Me_A_Coffee-FFDD00?style=for-the-badge&logo=buy-me-a-coffee&logoColor=black)](https://buymeacoffee.com/krobert)


<details>
<summary><b>Direct Crypto Wallet Addresses</b></summary>

* **BTC (SEGWIT):** `bc1qp69su3jeztapz8v9j67xman0kjru37tkd34rv0`
* **ETH (ERC20):** `0xf43c044b08e3889692c6990f59614597573f72b3`
* **SOL:** `FdE7AH4i8WTVgiCdfWXgnMYu8896fK11qLHckamxHF7v`
</details>