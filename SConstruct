#!/usr/bin/env python
import os
import sys

from methods import print_error

libname = "ladybug"
projectdir = os.path.join(Dir('.').abspath, "demo/addons")

localEnv = Environment(tools=["default"], PLATFORM="")

# Build profiles can be used to decrease compile times.
# localEnv["build_profile"] = "build_profile.json"

customs = ["custom.py"]
customs = [os.path.abspath(path) for path in customs]

opts = Variables(customs, ARGUMENTS)
opts.Update(localEnv)

Help(opts.GenerateHelpText(localEnv))

env = localEnv.Clone()

if not (os.path.isdir("godot-cpp") and os.listdir("godot-cpp")):
    print_error(
        """godot-cpp is not available within this folder, as Git submodules haven't been initialized.
Run the following command to download godot-cpp:

    git submodule update --init --recursive"""
    )
    sys.exit(1)

env = SConscript("godot-cpp/SConstruct", {"env": env, "customs": customs})

# --- Ladybug integration ---
ladybug_base = "thirdparty"
if env["platform"] == "linux":
    ladybug_dir = os.path.join(ladybug_base, "liblbug-linux-x86_64")
    env.Append(LIBS=["lbug", "pthread", "dl"])
elif env["platform"] == "macos":
    ladybug_dir = os.path.join(ladybug_base, "liblbug-osx-arm64")
    env.Append(LIBS=["lbug"])
    env.Append(LINKFLAGS=["-Wl,-rpath,@loader_path"])
elif env["platform"] == "windows":
    ladybug_dir = os.path.join(ladybug_base, "liblbug-windows-x86_64") # Ensure this folder exists in your thirdparty dir
    env.Append(LIBS=["lbug"])
else:
    print_error("Ladybug not configured for platform: " + env["platform"])
    sys.exit(1)

env.Append(CPPPATH=[ladybug_dir])
env.Append(LIBPATH=[ladybug_dir])
# --- end Ladybug ---

env.Append(CPPPATH=["src/"])
sources = Glob("src/*.cpp")

if env["target"] in ["editor", "template_debug"]:
    try:
        doc_data = env.GodotCPPDocData(
            "src/gen/doc_data.gen.cpp", source=Glob("doc_classes/*.xml")
        )
        sources.append(doc_data)
    except AttributeError:
        print("Not including class reference as we're targeting a pre-4.3 baseline.")

suffix = env["suffix"].replace(".dev", "").replace(".universal", "")

lib_filename = "{}{}{}{}".format(
    env.subst("$SHLIBPREFIX"), libname, suffix, env.subst("$SHLIBSUFFIX")
)

target_dir = os.path.join(Dir('.').abspath, "demo", "addons", "bin", env["platform"])

library = env.SharedLibrary(
    target=os.path.join(target_dir, lib_filename),
    source=sources,
)

if env["platform"] == "macos":
    src_dylib = os.path.join(ladybug_dir, "liblbug.0.17.1.dylib")
    lib0 = env.InstallAs(os.path.join(target_dir, "liblbug.0.dylib"), src_dylib)
    lib1 = env.InstallAs(os.path.join(target_dir, "liblbug.dylib"), src_dylib)
    env.AddPostAction([library, lib0, lib1], 'xattr -c "$TARGET"')
    default_args = [library, lib0, lib1]

elif env["platform"] == "windows":
    lib_copy = env.Install(target_dir, os.path.join(ladybug_dir, "lbug.dll"))
    default_args = [library, lib_copy]

elif env["platform"] == "linux":
    lib_copy = env.Install(target_dir, os.path.join(ladybug_dir, "liblbug.so"))
    default_args = [library, lib_copy]

else:
    default_args = [library]

Default(*default_args)