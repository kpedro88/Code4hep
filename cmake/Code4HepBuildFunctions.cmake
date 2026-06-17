# Code4HepBuildFunctions.cmake
# CMake helper-function library for the CODE4hep HEP software framework.
# Provides high-level wrappers around raw CMake boilerplate and the Stitched
# upstream helper functions (StitchedMacros.cmake).
#
# Downstream packages get these functions automatically via:
#   find_package(code4hep REQUIRED)
#
# CMake minimum version: 3.23 (required for FILE_SET HEADERS).

cmake_minimum_required(VERSION 3.23)

# ---------------------------------------------------------------------------
# Internal helper: derive target name from directory path.
#
# Algorithm:
#   1. Compute CMAKE_CURRENT_SOURCE_DIR relative to CMAKE_SOURCE_DIR.
#   2. Drop the first path component (the redundant inner repo/ directory).
#   3. Replace remaining '/' with '_'.
#
# Examples:
#   code4hep/DataFormats       -> DataFormats
#   code4hep/PodioUtilities    -> PodioUtilities
#   stitched/FWCore/Common     -> FWCore_Common
# ---------------------------------------------------------------------------
function(_c4h_derive_target_name OUT_VAR OUT_PATH_VAR)
    file(RELATIVE_PATH _rel "${CMAKE_SOURCE_DIR}" "${CMAKE_CURRENT_SOURCE_DIR}")
    # Drop the first component (inner repo dir)
    string(REGEX REPLACE "^[^/]+/" "" _stripped "${_rel}")
    # Package path (before replacing slashes) — used for C4H_PACKAGE_PATH
    set(${OUT_PATH_VAR} "${_stripped}" PARENT_SCOPE)
    # Target name: replace / with _
    string(REPLACE "/" "_" _target "${_stripped}")
    set(${OUT_VAR} "${_target}" PARENT_SCOPE)
endfunction()

# ---------------------------------------------------------------------------
# c4h_register_upstream(project_name)
# Appends project_name to the global CMake property C4H_UPSTREAM_PROJECTS.
# Called automatically by code4hepConfig.cmake for stitched; call it
# explicitly in the top-level CMakeLists.txt for additional upstreams.
# ---------------------------------------------------------------------------
function(c4h_register_upstream project_name)
    set_property(GLOBAL APPEND PROPERTY C4H_UPSTREAM_PROJECTS "${project_name}")
endfunction()

# ---------------------------------------------------------------------------
# Automatic find_package() for EXT_DEPS targets.
#
# When a developer writes EXT_DEPS podio::podio (or ROOT::Core, TBB::tbb,
# etc.), the c4h_* functions call _c4h_auto_find_package() with the namespace
# extracted from the target string.  The rules are:
#
#   Default:  find_package(<namespace> REQUIRED)
#   Override: if C4H_EXT_NAME_<namespace> is set, use that as the package name.
#             if C4H_EXT_ARGS_<namespace> is set, append it after REQUIRED.
#
# Built-in overrides cover the two real exception categories:
#   Name differs from namespace:  SQLite  → SQLite3
#   Needs CONFIG mode:            podio, EDM4HEP, cmsswdata, nlohmann_json, HepMC3
#
# Everything else (ROOT, TBB, Boost, Eigen3, CLHEP, Python3, XROOTD, ZLIB,
# BZip2, LibLZMA, OpenSSL, …) works with the default rule, so no entry is
# needed for them at all.
#
# c4h_register_ext_package(NAMESPACE <ns> [PACKAGE <name>] [EXTRA_ARGS <...>])
# adds or overrides a mapping for project-specific externals.
# ---------------------------------------------------------------------------

# Built-in exceptions — set once at include time via a guard property.
get_property(_c4h_ext_init GLOBAL PROPERTY C4H_EXT_INIT SET)
if(NOT _c4h_ext_init)
    set_property(GLOBAL PROPERTY C4H_EXT_INIT TRUE)
    # Name differs from namespace
    set_property(GLOBAL PROPERTY C4H_EXT_NAME_SQLite "SQLite3")
    # Packages that require CONFIG mode
    foreach(_ns IN ITEMS podio EDM4HEP cmsswdata nlohmann_json HepMC3)
        set_property(GLOBAL PROPERTY "C4H_EXT_ARGS_${_ns}" "CONFIG")
    endforeach()
endif()

# ---------------------------------------------------------------------------
# c4h_register_ext_package(NAMESPACE <ns> [PACKAGE <name>] [EXTRA_ARGS <...>])
#
# Register or override the find_package() behaviour for a CMake namespace.
# Only needed for packages where the default rule (find_package(<namespace>
# REQUIRED)) does not work — i.e., the package name differs from the namespace,
# or CONFIG / other args are required.
#
# NAMESPACE   The namespace prefix appearing before '::' in the CMake target
#             (e.g. "MyLib" for "MyLib::Core").
# PACKAGE     Package name passed to find_package(). Defaults to NAMESPACE.
# EXTRA_ARGS  Arguments appended after REQUIRED (e.g. CONFIG, or version req).
#
# Examples:
#   # Package ships only a CMake config file:
#   c4h_register_ext_package(NAMESPACE Acts EXTRA_ARGS CONFIG)
#
#   # Package name does not match namespace:
#   c4h_register_ext_package(NAMESPACE SQLite PACKAGE SQLite3)
# ---------------------------------------------------------------------------
function(c4h_register_ext_package)
    cmake_parse_arguments(_REG "" "NAMESPACE;PACKAGE" "EXTRA_ARGS" ${ARGN})
    if(NOT _REG_NAMESPACE)
        message(FATAL_ERROR "c4h_register_ext_package: NAMESPACE is required.")
    endif()
    if(_REG_PACKAGE)
        set_property(GLOBAL PROPERTY "C4H_EXT_NAME_${_REG_NAMESPACE}" "${_REG_PACKAGE}")
    endif()
    if(_REG_EXTRA_ARGS)
        string(JOIN " " _extra ${_REG_EXTRA_ARGS})
        set_property(GLOBAL PROPERTY "C4H_EXT_ARGS_${_REG_NAMESPACE}" "${_extra}")
    endif()
endfunction()

# ---------------------------------------------------------------------------
# Internal: call find_package() for the package that provides <namespace>::
# targets, using the override properties if present, defaulting to
# find_package(<namespace> REQUIRED).  Idempotent — CMake's find_package
# caching makes repeated calls free once the package is found.
# ---------------------------------------------------------------------------
function(_c4h_auto_find_package namespace)
    get_property(_pkg_name GLOBAL PROPERTY "C4H_EXT_NAME_${namespace}")
    if(NOT _pkg_name)
        set(_pkg_name "${namespace}")
    endif()
    get_property(_extra GLOBAL PROPERTY "C4H_EXT_ARGS_${namespace}")
    find_package(${_pkg_name} REQUIRED ${_extra})
endfunction()

# ---------------------------------------------------------------------------
# Internal helper: resolve a single DEPS shorthand string to a CMake target.
#
# Resolution rules:
#   1. Contains '::' -> already fully-qualified, pass through.
#   2. Contains '/'  -> two-component; replace '/' with '_', search all
#                       registered upstreams for <upstream>::<name>.
#                       FATAL_ERROR if nothing resolves.
#   3. Single component -> bare target in the build tree.
#                          FATAL_ERROR if target does not exist.
# ---------------------------------------------------------------------------
function(_c4h_resolve_dep DEP OUT_VAR)
    if("${DEP}" MATCHES "::")
        # Already fully-qualified CMake target.
        # Extract namespace and ensure the providing package is found.
        string(REGEX MATCH "^[^:]+" _ns "${DEP}")
        _c4h_auto_find_package("${_ns}")
        set(${OUT_VAR} "${DEP}" PARENT_SCOPE)
        return()
    endif()

    if("${DEP}" MATCHES "/")
        string(REPLACE "/" "_" _bare "${DEP}")
        get_property(_upstreams GLOBAL PROPERTY C4H_UPSTREAM_PROJECTS)
        foreach(_up IN LISTS _upstreams)
            if(TARGET "${_up}::${_bare}")
                set(${OUT_VAR} "${_up}::${_bare}" PARENT_SCOPE)
                return()
            endif()
        endforeach()
        message(FATAL_ERROR
            "c4h: Cannot resolve dependency '${DEP}' (looked for "
            "${_bare} under upstreams: ${_upstreams}). "
            "Ensure the upstream is installed and registered via c4h_register_upstream().")
    else()
        # Single-component: bare same-repo build-tree target.
        # CMake target resolution happens at generate time, so the target does
        # not need to exist yet at the point this function runs (configure time).
        # We accept the name unconditionally and let the generator catch typos.
        set(${OUT_VAR} "${DEP}" PARENT_SCOPE)
    endif()
endfunction()

# ---------------------------------------------------------------------------
# Internal helper: resolve a list of DEPS shorthands.
# Sets OUT_VAR in caller scope to the resolved target list.
# ---------------------------------------------------------------------------
function(_c4h_resolve_deps DEPS_LIST OUT_VAR)
    set(_resolved)
    foreach(_dep IN LISTS DEPS_LIST)
        _c4h_resolve_dep("${_dep}" _r)
        list(APPEND _resolved "${_r}")
    endforeach()
    set(${OUT_VAR} "${_resolved}" PARENT_SCOPE)
endfunction()

# ---------------------------------------------------------------------------
# 1. c4h_add_library
#
# SCRAM equivalent: top-level <use> + <export><lib name="1"/>
# or named <library file="..."> blocks that are not plugins.
#
# Creates a shared library, installs it and its headers, and wires include
# paths for both build-tree and install-tree use.
#
# PRIVATE_DEPS / EXT_PRIVATE_DEPS: these arguments have no SCRAM equivalent
# (SCRAM makes no public/private distinction) and will never appear in
# converter-generated output. Use them when a library uses a dependency only
# in its .cc files and should not propagate it to consumers.
#
# Per-target compile flag overrides (USER_CXXFLAGS in SCRAM) are intentionally
# absent from Code4HepBuild functions. The correct CMake equivalents are:
#   - Debug symbols + no optimization (equivalent to USER_CXXFLAGS="-g -O0"):
#     configure with cmake -DCMAKE_BUILD_TYPE=Debug.
#   - Debug symbols alongside a release build:
#     configure with cmake -DCMAKE_CXX_FLAGS="-g".
#   - Per-target flags in the rare case a single package genuinely requires them:
#     call target_compile_options(<target> PRIVATE -g -O0) directly after
#     c4h_add_library().
# ---------------------------------------------------------------------------
function(c4h_add_library)
    cmake_parse_arguments(
        C4H_LIB
        "RECURSE_SOURCES;NO_SYMBOL_CHECK;NO_TIDY"
        "NAME;DICT_HEADER;DICT_XML"
        "SOURCES;HEADERS;EXCLUDE_SOURCES;DEPS;EXT_DEPS;PRIVATE_DEPS;EXT_PRIVATE_DEPS;INCLUDE_DIRS;INSTALL_SCRIPTS"
        ${ARGN}
    )

    # --- Derive or override target name ---
    _c4h_derive_target_name(_auto_target _pkg_path)
    if(C4H_LIB_NAME)
        set(_C4H_TARGET "${C4H_LIB_NAME}")
    else()
        set(_C4H_TARGET "${_auto_target}")
    endif()

    # --- Check PROJECT_VERSION ---
    if(NOT PROJECT_VERSION)
        message(FATAL_ERROR
            "c4h_add_library: PROJECT_VERSION is not set. "
            "Set it in the top-level project() call.")
    endif()

    # --- Source globbing ---
    if(C4H_LIB_SOURCES)
        set(_glob_patterns ${C4H_LIB_SOURCES})
    else()
        set(_glob_patterns "${CMAKE_CURRENT_SOURCE_DIR}/src/*.cc")
    endif()

    if(C4H_LIB_RECURSE_SOURCES)
        file(GLOB_RECURSE _sources ${_glob_patterns})
    else()
        file(GLOB _sources ${_glob_patterns})
    endif()

    # Warn about glob staleness (CMake does not re-configure on file changes)
    message(AUTHOR_WARNING
        "Source files may have changed in ${CMAKE_CURRENT_SOURCE_DIR}: re-run cmake")

    # Remove excluded sources
    if(C4H_LIB_EXCLUDE_SOURCES)
        foreach(_excl IN LISTS C4H_LIB_EXCLUDE_SOURCES)
            list(REMOVE_ITEM _sources "${CMAKE_CURRENT_SOURCE_DIR}/${_excl}")
            list(REMOVE_ITEM _sources "${_excl}")
        endforeach()
    endif()

    # --- Header globbing ---
    if(C4H_LIB_HEADERS)
        file(GLOB _headers ${C4H_LIB_HEADERS})
    else()
        file(GLOB _headers "${CMAKE_CURRENT_SOURCE_DIR}/*.h")
    endif()

    # --- Create library target ---
    add_library(${_C4H_TARGET} SHARED ${_sources})

    # --- Include directories ---
    target_include_directories(${_C4H_TARGET}
        PUBLIC
            $<BUILD_INTERFACE:${CMAKE_SOURCE_DIR}>
            $<INSTALL_INTERFACE:include>
    )
    if(C4H_LIB_INCLUDE_DIRS)
        target_include_directories(${_C4H_TARGET} PRIVATE ${C4H_LIB_INCLUDE_DIRS})
    endif()

    # --- FILE_SET HEADERS (CMake 3.23+) ---
    if(_headers)
        target_sources(${_C4H_TARGET}
            PUBLIC
            FILE_SET HEADERS
            BASE_DIRS "${CMAKE_SOURCE_DIR}"
            FILES ${_headers}
        )
    endif()

    # --- Dependency resolution and linking ---
    _c4h_resolve_deps("${C4H_LIB_DEPS}" _pub_deps)
    _c4h_resolve_deps("${C4H_LIB_PRIVATE_DEPS}" _priv_deps)

    if(_pub_deps OR C4H_LIB_EXT_DEPS)
        target_link_libraries(${_C4H_TARGET}
            PUBLIC ${_pub_deps} ${C4H_LIB_EXT_DEPS}
        )
    endif()
    if(_priv_deps OR C4H_LIB_EXT_PRIVATE_DEPS)
        target_link_libraries(${_C4H_TARGET}
            PRIVATE ${_priv_deps} ${C4H_LIB_EXT_PRIVATE_DEPS}
        )
    endif()

    # --- Symbol checking: -Wl,--no-undefined (Linux only) ---
    if(NOT C4H_LIB_NO_SYMBOL_CHECK AND CMAKE_SYSTEM_NAME STREQUAL "Linux")
        target_link_options(${_C4H_TARGET} PRIVATE "-Wl,--no-undefined")
    endif()

    # --- Version and SOVERSION ---
    string(REGEX MATCH "^[0-9]+" _C4H_MAJOR "${PROJECT_VERSION}")
    set_target_properties(${_C4H_TARGET} PROPERTIES
        VERSION   "${PROJECT_VERSION}"
        SOVERSION "${_C4H_MAJOR}"
    )

    # --- Extension hook: package path property ---
    set_target_properties(${_C4H_TARGET} PROPERTIES
        C4H_PACKAGE_PATH "${_pkg_path}"
    )

    # --- Accumulate global properties ---
    set_property(GLOBAL APPEND PROPERTY C4H_BUILT_PACKAGES "${_C4H_TARGET}")
    set_property(GLOBAL APPEND PROPERTY C4H_ALL_SOURCES ${_sources})

    # --- Auto-detect ROOT dictionary ---
    if(C4H_LIB_DICT_HEADER)
        set(_dict_header "${C4H_LIB_DICT_HEADER}")
    else()
        set(_dict_header "src/classes.h")
    endif()
    if(C4H_LIB_DICT_XML)
        set(_dict_xml "${C4H_LIB_DICT_XML}")
    else()
        set(_dict_xml "src/classes_def.xml")
    endif()

    if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/${_dict_header}" AND
       EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/${_dict_xml}")
        message(STATUS
            "c4h: Auto-detected ROOT dictionary for ${_C4H_TARGET} "
            "(${_dict_header}, ${_dict_xml})")
        c4h_generate_dictionary(
            TARGET  "${_C4H_TARGET}"
            HEADERS "${CMAKE_CURRENT_SOURCE_DIR}/${_dict_header}"
            LINKDEF "${CMAKE_CURRENT_SOURCE_DIR}/${_dict_xml}"
        )
    endif()

    # --- Install scripts ---
    if(C4H_LIB_INSTALL_SCRIPTS)
        install(PROGRAMS ${C4H_LIB_INSTALL_SCRIPTS}
            DESTINATION "${CMAKE_INSTALL_BINDIR}"
        )
    endif()

    # --- Install: library + headers + export set ---
    install(TARGETS ${_C4H_TARGET}
        EXPORT  "${PROJECT_NAME}Targets"
        LIBRARY DESTINATION "${CMAKE_INSTALL_LIBDIR}"
        FILE_SET HEADERS
    )

    # --- clang-tidy suppression ---
    if(C4H_LIB_NO_TIDY)
        set_target_properties(${_C4H_TARGET} PROPERTIES CXX_CLANG_TIDY "")
    endif()
endfunction()

# ---------------------------------------------------------------------------
# 2. c4h_add_plugin
#
# SCRAM equivalent: <library> with <flags EDM_PLUGIN="1"/>
# Wraps stitched_generate_plugin. Provides DEPS shorthand resolution,
# auto-globbing, EXCLUDE_SOURCES, and a NO_CFIPYTHON escape for plugins
# that do not implement fillDescriptions().
#
# Because all user-defined plugin factories subclass the base PluginFactory
# class, edmWriteConfigs works uniformly for all plugin types.
#
# Per-target compile flag overrides are intentionally absent. See the note
# in c4h_add_library for the correct CMAKE_BUILD_TYPE-based equivalents.
# ---------------------------------------------------------------------------
function(c4h_add_plugin)
    cmake_parse_arguments(
        C4H_PLG
        "NO_TIDY;NO_CFIPYTHON"
        "NAME"
        "SOURCES;EXCLUDE_SOURCES;DEPS;EXT_DEPS;INCLUDE_DIRS"
        ${ARGN}
    )

    if(NOT C4H_PLG_NAME)
        message(FATAL_ERROR "c4h_add_plugin: NAME is required.")
    endif()

    set(_target "plugin_${C4H_PLG_NAME}")

    # --- Derive package path (for C4H_PACKAGE_PATH property) ---
    _c4h_derive_target_name(_auto_target _pkg_path)

    # --- Source globbing ---
    if(C4H_PLG_SOURCES)
        file(GLOB _sources ${C4H_PLG_SOURCES})
    else()
        # If we are inside a plugins/ directory, glob *.cc; otherwise plugins/*.cc
        get_filename_component(_curdir "${CMAKE_CURRENT_SOURCE_DIR}" NAME)
        if("${_curdir}" STREQUAL "plugins")
            file(GLOB _sources "${CMAKE_CURRENT_SOURCE_DIR}/*.cc")
        else()
            file(GLOB _sources "${CMAKE_CURRENT_SOURCE_DIR}/plugins/*.cc")
        endif()
    endif()

    message(AUTHOR_WARNING
        "Source files may have changed in ${CMAKE_CURRENT_SOURCE_DIR}: re-run cmake")

    if(C4H_PLG_EXCLUDE_SOURCES)
        foreach(_excl IN LISTS C4H_PLG_EXCLUDE_SOURCES)
            list(REMOVE_ITEM _sources "${CMAKE_CURRENT_SOURCE_DIR}/${_excl}")
            list(REMOVE_ITEM _sources "${_excl}")
        endforeach()
    endif()

    # --- Resolve deps ---
    _c4h_resolve_deps("${C4H_PLG_DEPS}" _resolved_deps)
    set(_link_libs ${_resolved_deps} ${C4H_PLG_EXT_DEPS})

    # --- Create plugin target ---
    if(C4H_PLG_NO_CFIPYTHON)
        # Manual plugin creation without edmWriteConfigs
        add_library(${_target} SHARED ${_sources})
        set_target_properties(${_target} PROPERTIES PREFIX "edmplugin")
        target_include_directories(${_target}
            PUBLIC
                $<BUILD_INTERFACE:${CMAKE_SOURCE_DIR}>
                $<INSTALL_INTERFACE:include>
        )
        if(_link_libs)
            target_link_libraries(${_target} PUBLIC ${_link_libs})
        endif()
        install(TARGETS ${_target}
            LIBRARY DESTINATION "${CMAKE_INSTALL_LIBDIR}"
        )
    else()
        # Delegate to stitched_generate_plugin (handles edmWriteConfigs,
        # modules.py installation, and python/ directory handling).
        # SCRAM equivalent: stitched_generate_plugin macro in StitchedMacros.cmake
        stitched_generate_plugin(
            TARGET         "${_target}"
            SOURCES        ${_sources}
            LINK_LIBRARIES ${_link_libs}
        )
    endif()

    # --- Extra include directories (applies to both cases) ---
    if(C4H_PLG_INCLUDE_DIRS)
        target_include_directories(${_target} PRIVATE ${C4H_PLG_INCLUDE_DIRS})
    endif()

    # --- Extension hook properties ---
    set_target_properties(${_target} PROPERTIES
        C4H_IS_PLUGIN   TRUE
        C4H_PACKAGE_PATH "${_pkg_path}"
    )

    # --- Accumulate global properties ---
    set_property(GLOBAL APPEND PROPERTY C4H_PLUGIN_TARGETS "${_target}")
    set_property(GLOBAL APPEND PROPERTY C4H_ALL_SOURCES ${_sources})

    # --- clang-tidy suppression ---
    if(C4H_PLG_NO_TIDY)
        set_target_properties(${_target} PROPERTIES CXX_CLANG_TIDY "")
    endif()
endfunction()

# ---------------------------------------------------------------------------
# 3. c4h_add_executable
#
# SCRAM equivalent: <bin name="..." file="...">
# Builds and installs a binary executable.
# Distinct from c4h_add_test_binary (which builds but does not install).
# ---------------------------------------------------------------------------
function(c4h_add_executable)
    cmake_parse_arguments(
        C4H_EXE
        ""
        "NAME"
        "SOURCES;EXCLUDE_SOURCES;DEPS;EXT_DEPS;INCLUDE_DIRS;INSTALL_SCRIPTS"
        ${ARGN}
    )

    if(NOT C4H_EXE_NAME)
        message(FATAL_ERROR "c4h_add_executable: NAME is required.")
    endif()

    set(_target "bin_${C4H_EXE_NAME}")

    # --- Source globbing ---
    if(C4H_EXE_SOURCES)
        file(GLOB _sources ${C4H_EXE_SOURCES})
    elseif(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/bin/${C4H_EXE_NAME}.cc")
        set(_sources "${CMAKE_CURRENT_SOURCE_DIR}/bin/${C4H_EXE_NAME}.cc")
    else()
        file(GLOB _sources "${CMAKE_CURRENT_SOURCE_DIR}/bin/*.cc")
    endif()

    message(AUTHOR_WARNING
        "Source files may have changed in ${CMAKE_CURRENT_SOURCE_DIR}: re-run cmake")

    if(C4H_EXE_EXCLUDE_SOURCES)
        foreach(_excl IN LISTS C4H_EXE_EXCLUDE_SOURCES)
            list(REMOVE_ITEM _sources "${CMAKE_CURRENT_SOURCE_DIR}/${_excl}")
            list(REMOVE_ITEM _sources "${_excl}")
        endforeach()
    endif()

    add_executable(${_target} ${_sources})

    if(C4H_EXE_INCLUDE_DIRS)
        target_include_directories(${_target} PRIVATE ${C4H_EXE_INCLUDE_DIRS})
    endif()

    _c4h_resolve_deps("${C4H_EXE_DEPS}" _resolved_deps)
    set(_link_libs ${_resolved_deps} ${C4H_EXE_EXT_DEPS})
    if(_link_libs)
        target_link_libraries(${_target} PRIVATE ${_link_libs})
    endif()

    install(TARGETS ${_target}
        EXPORT  "${PROJECT_NAME}Targets"
        RUNTIME DESTINATION "${CMAKE_INSTALL_BINDIR}"
    )

    if(C4H_EXE_INSTALL_SCRIPTS)
        install(PROGRAMS ${C4H_EXE_INSTALL_SCRIPTS}
            DESTINATION "${CMAKE_INSTALL_BINDIR}"
        )
    endif()
endfunction()

# ---------------------------------------------------------------------------
# 4. c4h_generate_plugincache
#
# Wraps stitched_generate_plugincache (StitchedMacros.cmake).
# Automatically uses the C4H_PLUGIN_TARGETS global property accumulated by
# all c4h_add_plugin calls — no manual enumeration needed.
#
# Call once in the top-level CMakeLists.txt after all add_subdirectory() calls.
# ---------------------------------------------------------------------------
function(c4h_generate_plugincache)
    cmake_parse_arguments(
        C4H_PC
        ""
        "OUTPUT_DIR;TARGET_NAME"
        ""
        ${ARGN}
    )

    get_property(_plugin_targets GLOBAL PROPERTY C4H_PLUGIN_TARGETS)
    if(NOT _plugin_targets)
        message(FATAL_ERROR
            "c4h_generate_plugincache: No plugin targets registered. "
            "Ensure c4h_add_plugin() has been called before this function.")
    endif()

    set(_args PLUGIN_TARGETS ${_plugin_targets})

    if(C4H_PC_OUTPUT_DIR)
        list(APPEND _args OUTPUT_DIR "${C4H_PC_OUTPUT_DIR}")
    endif()

    if(C4H_PC_TARGET_NAME)
        list(APPEND _args CACHE_TARGET_NAME "${C4H_PC_TARGET_NAME}")
    else()
        list(APPEND _args CACHE_TARGET_NAME "RefreshPluginCache")
    endif()

    # Delegates to Stitched: stitched_generate_plugincache in StitchedMacros.cmake
    stitched_generate_plugincache(${_args})
endfunction()

# ---------------------------------------------------------------------------
# 5. c4h_add_test
#
# SCRAM equivalent: <test name="..." command="...">
# Registers a script-based test with CTest.
#
# NOTE: SCRAM's SETENV_SCRIPT (sourcing a shell script before the test) has
# no clean CTest equivalent and is intentionally unsupported. Tests that
# relied on SETENV_SCRIPT must be refactored to pass required values as
# explicit ENVIRONMENT entries or to bake them into the test command.
# ---------------------------------------------------------------------------
function(c4h_add_test)
    cmake_parse_arguments(
        C4H_TST
        ""
        "NAME;WORKING_DIRECTORY"
        "COMMAND;DEPS;EXT_DEPS;ENVIRONMENT;DEPENDS"
        ${ARGN}
    )

    if(NOT C4H_TST_NAME)
        message(FATAL_ERROR "c4h_add_test: NAME is required.")
    endif()
    if(NOT C4H_TST_COMMAND)
        message(FATAL_ERROR "c4h_add_test: COMMAND is required.")
    endif()

    # Substitute ${LOCALTOP} -> ${CMAKE_SOURCE_DIR}
    set(_cmd)
    foreach(_tok IN LISTS C4H_TST_COMMAND)
        string(REPLACE "\${LOCALTOP}" "${CMAKE_SOURCE_DIR}" _tok "${_tok}")
        list(APPEND _cmd "${_tok}")
    endforeach()

    if(C4H_TST_WORKING_DIRECTORY)
        set(_workdir "${C4H_TST_WORKING_DIRECTORY}")
    else()
        set(_workdir "${CMAKE_CURRENT_SOURCE_DIR}")
    endif()

    # Resolve deps and collect library dirs for LD_LIBRARY_PATH
    _c4h_resolve_deps("${C4H_TST_DEPS}" _resolved_deps)
    set(_lib_dirs)
    foreach(_dep IN LISTS _resolved_deps)
        if(TARGET "${_dep}")
            list(APPEND _lib_dirs "$<TARGET_FILE_DIR:${_dep}>")
        endif()
    endforeach()

    add_test(NAME "${C4H_TST_NAME}"
        COMMAND ${_cmd}
        WORKING_DIRECTORY "${_workdir}"
    )

    # Build ENVIRONMENT property
    set(_env_list)
    if(_lib_dirs)
        if(CMAKE_SYSTEM_NAME STREQUAL "Darwin")
            set(_ld_var "DYLD_LIBRARY_PATH")
        else()
            set(_ld_var "LD_LIBRARY_PATH")
        endif()
        string(JOIN ":" _lib_path_str ${_lib_dirs})
        list(APPEND _env_list "${_ld_var}=${_lib_path_str}:\$ENV{${_ld_var}}")
    endif()
    foreach(_kv IN LISTS C4H_TST_ENVIRONMENT)
        list(APPEND _env_list "${_kv}")
    endforeach()

    if(_env_list)
        set_tests_properties("${C4H_TST_NAME}" PROPERTIES
            ENVIRONMENT "${_env_list}"
        )
    endif()

    if(C4H_TST_DEPENDS)
        set_tests_properties("${C4H_TST_NAME}" PROPERTIES
            DEPENDS "${C4H_TST_DEPENDS}"
        )
    endif()

    # Package label for ctest -L filtering
    _c4h_derive_target_name(_auto _pkg_path)
    set_tests_properties("${C4H_TST_NAME}" PROPERTIES
        LABELS "${_pkg_path}"
    )
endfunction()

# ---------------------------------------------------------------------------
# 6. c4h_add_test_binary
#
# SCRAM equivalent: <test> with a C++ executable source.
# Builds a C++ test executable and optionally registers it with CTest.
# Binary is NOT installed; not added to export set.
#
# BUILD_ONLY: build but do not register as a CTest test (SCRAM: NO_TESTRUN=1)
# ---------------------------------------------------------------------------
function(c4h_add_test_binary)
    cmake_parse_arguments(
        C4H_TB
        "BUILD_ONLY"
        "NAME;WORKING_DIRECTORY"
        "SOURCES;EXCLUDE_SOURCES;DEPS;EXT_DEPS;ENVIRONMENT;DEPENDS;COMMAND"
        ${ARGN}
    )

    if(NOT C4H_TB_NAME)
        message(FATAL_ERROR "c4h_add_test_binary: NAME is required.")
    endif()

    set(_target "test_${C4H_TB_NAME}")

    # --- Source globbing ---
    if(C4H_TB_SOURCES)
        file(GLOB _sources ${C4H_TB_SOURCES})
    elseif(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/test/${C4H_TB_NAME}.cc")
        set(_sources "${CMAKE_CURRENT_SOURCE_DIR}/test/${C4H_TB_NAME}.cc")
    else()
        file(GLOB _sources "${CMAKE_CURRENT_SOURCE_DIR}/test/*.cc")
    endif()

    message(AUTHOR_WARNING
        "Source files may have changed in ${CMAKE_CURRENT_SOURCE_DIR}: re-run cmake")

    if(C4H_TB_EXCLUDE_SOURCES)
        foreach(_excl IN LISTS C4H_TB_EXCLUDE_SOURCES)
            list(REMOVE_ITEM _sources "${CMAKE_CURRENT_SOURCE_DIR}/${_excl}")
            list(REMOVE_ITEM _sources "${_excl}")
        endforeach()
    endif()

    add_executable(${_target} ${_sources})
    # Exclude from default install target
    set_target_properties(${_target} PROPERTIES EXCLUDE_FROM_ALL TRUE)

    _c4h_resolve_deps("${C4H_TB_DEPS}" _resolved_deps)
    set(_link_libs ${_resolved_deps} ${C4H_TB_EXT_DEPS})
    if(_link_libs)
        target_link_libraries(${_target} PRIVATE ${_link_libs})
    endif()

    if(NOT C4H_TB_BUILD_ONLY)
        if(C4H_TB_COMMAND)
            set(_cmd ${C4H_TB_COMMAND})
        else()
            set(_cmd "$<TARGET_FILE:${_target}>")
        endif()

        if(C4H_TB_WORKING_DIRECTORY)
            set(_workdir "${C4H_TB_WORKING_DIRECTORY}")
        else()
            set(_workdir "${CMAKE_CURRENT_SOURCE_DIR}")
        endif()

        add_test(NAME "${C4H_TB_NAME}"
            COMMAND ${_cmd}
            WORKING_DIRECTORY "${_workdir}"
        )

        # Library path environment
        set(_lib_dirs)
        foreach(_dep IN LISTS _resolved_deps)
            if(TARGET "${_dep}")
                list(APPEND _lib_dirs "$<TARGET_FILE_DIR:${_dep}>")
            endif()
        endforeach()

        set(_env_list)
        if(_lib_dirs)
            if(CMAKE_SYSTEM_NAME STREQUAL "Darwin")
                set(_ld_var "DYLD_LIBRARY_PATH")
            else()
                set(_ld_var "LD_LIBRARY_PATH")
            endif()
            string(JOIN ":" _lib_path_str ${_lib_dirs})
            list(APPEND _env_list "${_ld_var}=${_lib_path_str}:\$ENV{${_ld_var}}")
        endif()
        foreach(_kv IN LISTS C4H_TB_ENVIRONMENT)
            list(APPEND _env_list "${_kv}")
        endforeach()

        if(_env_list)
            set_tests_properties("${C4H_TB_NAME}" PROPERTIES
                ENVIRONMENT "${_env_list}"
            )
        endif()

        if(C4H_TB_DEPENDS)
            set_tests_properties("${C4H_TB_NAME}" PROPERTIES
                DEPENDS "${C4H_TB_DEPENDS}"
            )
        endif()

        _c4h_derive_target_name(_auto _pkg_path)
        set_tests_properties("${C4H_TB_NAME}" PROPERTIES
            LABELS "${_pkg_path}"
        )
    endif()
endfunction()

# ---------------------------------------------------------------------------
# 7. c4h_generate_dictionary (internal helper, also callable directly)
#
# SCRAM equivalent: <flags LCG_DICT_HEADER="..." LCG_DICT_XML="..."/>
# Wraps stitched_generate_dictionary (StitchedMacros.cmake).
# Called automatically by c4h_add_library when dict files are detected.
# May also be called explicitly for packages needing multiple dictionaries.
# ---------------------------------------------------------------------------
function(c4h_generate_dictionary)
    cmake_parse_arguments(
        C4H_DICT
        ""
        "TARGET;HEADERS;LINKDEF"
        "OPTIONS"
        ${ARGN}
    )

    if(NOT C4H_DICT_TARGET)
        message(FATAL_ERROR "c4h_generate_dictionary: TARGET is required.")
    endif()

    if(NOT ROOT_FOUND)
        message(FATAL_ERROR
            "c4h_generate_dictionary: ROOT was not found. "
            "Add find_package(ROOT REQUIRED) before calling this function.")
    endif()

    if(NOT C4H_DICT_HEADERS)
        set(C4H_DICT_HEADERS "${CMAKE_CURRENT_SOURCE_DIR}/src/classes.h")
    endif()
    if(NOT C4H_DICT_LINKDEF)
        set(C4H_DICT_LINKDEF "${CMAKE_CURRENT_SOURCE_DIR}/src/classes_def.xml")
    endif()

    # Delegates to Stitched: stitched_generate_dictionary in StitchedMacros.cmake
    # (suppresses rootcling-endemic warnings on the generated source)
    stitched_generate_dictionary(${C4H_DICT_TARGET}_dict
        "${C4H_DICT_HEADERS}"
        LINKDEF "${C4H_DICT_LINKDEF}"
        MODULE  "${C4H_DICT_TARGET}"
        OPTIONS --reflex ${C4H_DICT_OPTIONS}
    )
endfunction()

# ---------------------------------------------------------------------------
# c4h_auto_subdirectories([EXCLUDE <dirs...>])
#
# Automatically calls add_subdirectory() for every direct child directory of
# CMAKE_CURRENT_SOURCE_DIR that contains a CMakeLists.txt.  Directories are
# processed in alphabetical order.
#
# Use this in mid-level (structural) CMakeLists.txt files — those that exist
# only to wire subdirectories together and have no c4h_add_library() call of
# their own.  It can also be used at the package level to pull in a plugins/
# or test/ subdirectory automatically.
#
# EXCLUDE: directory names (not paths) to skip.
#
# Like source globbing, this relies on a glob at configure time and will not
# pick up new subdirectories without a cmake re-run.  The staleness warning
# is emitted to make this visible.
# ---------------------------------------------------------------------------
function(c4h_auto_subdirectories)
    cmake_parse_arguments(C4H_ASD "" "" "EXCLUDE" ${ARGN})

    file(GLOB _children
        LIST_DIRECTORIES true
        RELATIVE "${CMAKE_CURRENT_SOURCE_DIR}"
        "${CMAKE_CURRENT_SOURCE_DIR}/*"
    )

    message(AUTHOR_WARNING
        "Subdirectory list may have changed in ${CMAKE_CURRENT_SOURCE_DIR}: re-run cmake")

    foreach(_child IN LISTS _children)
        if(IS_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/${_child}")
            if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/${_child}/CMakeLists.txt")
                if(NOT "${_child}" IN_LIST C4H_ASD_EXCLUDE)
                    add_subdirectory("${_child}")
                endif()
            endif()
        endif()
    endforeach()
endfunction()

# ---------------------------------------------------------------------------
# Top-level utility: format target
#
# Runs clang-format -i over all sources accumulated in C4H_ALL_SOURCES.
# Define this target once in the top-level CMakeLists.txt after all
# add_subdirectory() calls (so C4H_ALL_SOURCES is fully populated).
# ---------------------------------------------------------------------------
function(c4h_add_format_target)
    get_property(_all_sources GLOBAL PROPERTY C4H_ALL_SOURCES)
    find_program(CLANG_FORMAT_EXECUTABLE clang-format)
    if(CLANG_FORMAT_EXECUTABLE)
        add_custom_target(format
            COMMAND "${CLANG_FORMAT_EXECUTABLE}" -i ${_all_sources}
            COMMENT "Running clang-format over all Code4HEP sources"
        )
    else()
        message(STATUS "c4h: clang-format not found; 'format' target disabled.")
    endif()
endfunction()
