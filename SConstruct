#!/usr/bin/env python
import os
import sys
from methods import print_error

projectdir = os.path.join(Dir(".").abspath, "demo/addons")

localEnv = Environment(tools=["default"], PLATFORM="")
customs = [os.path.abspath(path) for path in ["custom.py"]]

# Define custom build variables
opts = Variables(customs, ARGUMENTS)
opts.Add(BoolVariable("build_ladybug", "Build the Ladybug Database module", True))
opts.Add(
    EnumVariable(
        "build_mcp",
        "Build the MCP module backend",
        "rapid",
        allowed_values=("no", "glaze", "rapid"),
    )
)
opts.Update(localEnv)

Help(opts.GenerateHelpText(localEnv))
env = localEnv.Clone()

if not (os.path.isdir("godot-cpp") and os.listdir("godot-cpp")):
    print_error(
        "godot-cpp not initialized. Run: git submodule update --init --recursive"
    )
    sys.exit(1)

env = SConscript("godot-cpp/SConstruct", {"env": env, "customs": customs})
suffix = env["suffix"].replace(".dev", "").replace(".universal", "")
default_args = []

# --- LADYBUG MODULE ---
if env["build_ladybug"]:
    lb_env = env.Clone()
    ladybug_base = "thirdparty/ladybug"
    if lb_env["platform"] == "linux":
        lb_dir = os.path.join(ladybug_base, "liblbug-linux-x86_64")
        lb_env.Append(LIBS=["lbug", "pthread", "dl"])
    elif lb_env["platform"] == "macos":
        lb_dir = os.path.join(ladybug_base, "liblbug-osx-arm64")
        lb_env.Append(LIBS=["lbug"], LINKFLAGS=["-Wl,-rpath,@loader_path"])
    elif lb_env["platform"] == "windows":
        lb_dir = os.path.join(ladybug_base, "liblbug-windows-x86_64")
        lb_env.Append(LIBS=["lbug"])
    else:
        print_error("Ladybug not configured for platform: " + lb_env["platform"])
        sys.exit(1)

    lb_env.Append(CPPPATH=[lb_dir, "src/ladybug/"])
    lb_env.Append(LIBPATH=[lb_dir])

    lb_src = Glob("src/ladybug/*.cpp")
    if lb_env["target"] in ["editor", "template_debug"]:
        try:
            lb_src.append(
                lb_env.GodotCPPDocData(
                    "src/ladybug/gen/doc_data.gen.cpp",
                    source=Glob("doc_classes/ladybug/*.xml"),
                )
            )
        except AttributeError:
            pass

    lb_target_dir = os.path.join(projectdir, "ladybug", "bin", lb_env["platform"])
    lb_libname = "{}{}{}{}".format(
        lb_env.subst("$SHLIBPREFIX"), "ladybug", suffix, lb_env.subst("$SHLIBSUFFIX")
    )

    lb_lib = lb_env.SharedLibrary(
        target=os.path.join(lb_target_dir, lb_libname), source=lb_src
    )
    default_args.append(lb_lib)

    if lb_env["platform"] == "macos":
        src_dylib = os.path.join(lb_dir, "liblbug.0.17.1.dylib")
        lib0 = lb_env.InstallAs(
            os.path.join(lb_target_dir, "liblbug.0.dylib"), src_dylib
        )
        lib1 = lb_env.InstallAs(os.path.join(lb_target_dir, "liblbug.dylib"), src_dylib)
        lb_env.AddPostAction([lb_lib, lib0, lib1], 'xattr -c "$TARGET"')
        default_args.extend([lib0, lib1])
    elif lb_env["platform"] == "windows":
        default_args.append(
            lb_env.Install(lb_target_dir, os.path.join(lb_dir, "lbug.dll"))
        )
    elif lb_env["platform"] == "linux":
        default_args.append(
            lb_env.Install(lb_target_dir, os.path.join(lb_dir, "liblbug.so"))
        )

# --- MCP MODULE ---
if env["build_mcp"] != "no":
    mcp_env = env.Clone()

    # ---------------------------------------------------------
    # RAPIDJSON BACKEND
    # ---------------------------------------------------------
    if env["build_mcp"] == "rapid":
        mcp_env.Append(CPPPATH=["thirdparty/rapidjson/include", "src/rapidjson/"])
        mcp_src = Glob("src/rapidjson/*.cpp")

        doc_gen_target = "src/rapidjson/gen/doc_data.gen.cpp"
        doc_xml_source = Glob("doc_classes/rapidjson/*.xml")

    # ---------------------------------------------------------
    # GLAZE BACKEND (Legacy)
    # ---------------------------------------------------------
    elif env["build_mcp"] == "glaze":
        mcp_env.Append(CPPPATH=["thirdparty/glaze/include", "src/glaze/"])

        # Glaze requires modern C++ features
        if (
            mcp_env.get("is_msvc", False)
            or mcp_env.get("cc", "") == "msvc"
            or mcp_env.get("CC", "") == "cl"
        ):
            mcp_env.Append(CXXFLAGS=["/std:c++latest"])
        else:
            mcp_env.Append(CXXFLAGS=["-std=c++2b"])

        mcp_src = Glob("src/glaze/*.cpp")

        doc_gen_target = "src/glaze/gen/doc_data.gen.cpp"
        doc_xml_source = Glob("doc_classes/glaze/*.xml")

    # ---------------------------------------------------------
    # COMMON BUILD STEPS
    # ---------------------------------------------------------
    if mcp_env["target"] in ["editor", "template_debug"]:
        try:
            mcp_src.append(
                mcp_env.GodotCPPDocData(
                    doc_gen_target,
                    source=doc_xml_source,
                )
            )
        except AttributeError:
            pass

    mcp_target_dir = os.path.join(projectdir, "mcp", "bin", mcp_env["platform"])
    mcp_libname = "{}{}{}{}".format(
        mcp_env.subst("$SHLIBPREFIX"), "mcp", suffix, mcp_env.subst("$SHLIBSUFFIX")
    )

    mcp_lib = mcp_env.SharedLibrary(
        target=os.path.join(mcp_target_dir, mcp_libname), source=mcp_src
    )
    default_args.append(mcp_lib)

    if mcp_env["platform"] == "macos":
        mcp_env.AddPostAction(mcp_lib, 'xattr -c "$TARGET"')

Default(*default_args)
