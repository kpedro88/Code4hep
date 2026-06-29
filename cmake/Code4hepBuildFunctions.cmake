# Code4hepBuildFunctions.cmake
# CMake helper-function library for the Code4hep HEP software framework.
# Provides high-level wrappers around raw CMake boilerplate and the Stitched
# upstream helper functions (StitchedMacros.cmake).
#
# Downstream packages get these functions automatically via:
#   find_package(Code4hep REQUIRED)
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
#   Code4hep/DataFormats       -> DataFormats
#   Code4hep/PodioUtilities    -> PodioUtilities
#   Stitched/FWCore/Common     -> FWCore_Common
# ---------------------------------------------------------------------------
function(_c4h_derive_target_name OUT_VAR OUT_PATH_VAR)
    file(RELATIVE_PATH _rel "${CMAKE_SOURCE_DIR}" "${CMAKE_CURRENT_SOURCE_DIR}")
    # Drop the first component (inner repo dir)
    string(REGEX REPLACE "^[^/]+/" "" _stripped "${_rel}")
    # Package path (before replacing slashes) — used as the ctest LABEL
    set(${OUT_PATH_VAR} "${_stripped}" PARENT_SCOPE)
    # Target name: replace / with _
    string(REPLACE "/" "_" _target "${_stripped}")
    set(${OUT_VAR} "${_target}" PARENT_SCOPE)
endfunction()

# ---------------------------------------------------------------------------
# c4h_register_upstream(project_name)
# Appends project_name to the global CMake property C4H_UPSTREAM_PROJECTS.
# Called automatically by Code4hepConfig.cmake for Stitched; call it
# explicitly in the top-level CMakeLists.txt for additional upstreams.
# ---------------------------------------------------------------------------
function(c4h_register_upstream project_name)
    set_property(GLOBAL APPEND PROPERTY C4H_UPSTREAM_PROJECTS "${project_name}")
endfunction()

# ---------------------------------------------------------------------------
# Automatic find_package() for EXT_DEPS targets.
#
# When a developer writes EXT_DEPS podio::podio (or ROOT::Core, TBB::tbb, etc.),
# the c4h_* functions call _c4h_auto_find_package() with the namespace before
# the '::'.  By default it runs find_package(<namespace> REQUIRED); two global
# properties override that for the packages that need it:
#
#   C4H_EXT_NAME_<ns>   package name to look up, when it differs from <ns>
#   C4H_EXT_ARGS_<ns>   extra arguments appended after REQUIRED (e.g. CONFIG)
#
# To add an override for another external, set the matching property before the
# relevant c4h_add_* call, exactly as the built-ins below do. Everything else
# (ROOT, TBB, Boost, Eigen3, CLHEP, …) works with the default rule.
# ---------------------------------------------------------------------------

# All plugin .so files must land in a single flat directory so that
# edmPluginRefresh (which requires all its arguments to share one directory)
# can process them.  Override at cmake time with -DC4H_PLUGIN_OUTPUT_DIR=...
if(NOT DEFINED C4H_PLUGIN_OUTPUT_DIR)
    set(C4H_PLUGIN_OUTPUT_DIR "${CMAKE_BINARY_DIR}/edmplugin"
        CACHE PATH "Output directory for all edmplugin shared libraries")
endif()

# Built-in find_package() overrides — set once at include time.
get_property(_c4h_ext_init GLOBAL PROPERTY C4H_EXT_INIT SET)
if(NOT _c4h_ext_init)
    set_property(GLOBAL PROPERTY C4H_EXT_INIT TRUE)
    # Name differs from namespace
    set_property(GLOBAL PROPERTY C4H_EXT_NAME_SQLite "SQLite3")
    # Packages that require CONFIG mode
    foreach(_ns IN ITEMS podio EDM4HEP cmsswdata nlohmann_json HepMC3)
        set_property(GLOBAL PROPERTY "C4H_EXT_ARGS_${_ns}" "CONFIG")
    endforeach()
    # Packages that require specific components
    set_property(GLOBAL PROPERTY C4H_EXT_ARGS_Python3 "COMPONENTS Development Interpreter")
    # Catch2: always use CONFIG mode.  (_c4h_resolve_dep additionally rewrites
    # Catch2::Catch2 to Catch2::Catch2WithMain, which supplies main().)
    set_property(GLOBAL PROPERTY C4H_EXT_ARGS_Catch2 "CONFIG")
endif()

# ---------------------------------------------------------------------------
# Internal: call find_package() for the package that provides <namespace>::
# targets, using the override properties if present, defaulting to
# find_package(<namespace> REQUIRED).
#
# find_package runs at most once per package: the first c4h_add_* call that
# references the namespace finds it, and the imported targets are promoted to
# GLOBAL scope so every sibling package directory can link against them. The
# once-only guard is required for FindPython3, which errors when re-invoked
# with COMPONENTS in a nested directory scope.
# ---------------------------------------------------------------------------
function(_c4h_auto_find_package namespace)
    get_property(_pkg_name GLOBAL PROPERTY "C4H_EXT_NAME_${namespace}")
    if(NOT _pkg_name)
        set(_pkg_name "${namespace}")
    endif()
    get_property(_already GLOBAL PROPERTY "C4H_EXT_FOUND_${_pkg_name}")
    if(_already)
        return()
    endif()
    set_property(GLOBAL PROPERTY "C4H_EXT_FOUND_${_pkg_name}" TRUE)

    get_property(_extra GLOBAL PROPERTY "C4H_EXT_ARGS_${namespace}")
    get_property(_before DIRECTORY PROPERTY IMPORTED_TARGETS)
    find_package(${_pkg_name} REQUIRED ${_extra})
    # Promote newly-imported targets to GLOBAL so packages in sibling
    # directories (found-once elsewhere) can still link them.
    get_property(_after DIRECTORY PROPERTY IMPORTED_TARGETS)
    foreach(_tgt IN LISTS _after)
        if(NOT "${_tgt}" IN_LIST _before)
            set_target_properties("${_tgt}" PROPERTIES IMPORTED_GLOBAL TRUE)
        endif()
    endforeach()
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
        # Catch2::Catch2 has no main(); redirect to the variant that does so
        # test binaries link correctly without a hand-written main().
        if("${DEP}" STREQUAL "Catch2::Catch2")
            set(${OUT_VAR} "Catch2::Catch2WithMain" PARENT_SCOPE)
        else()
            set(${OUT_VAR} "${DEP}" PARENT_SCOPE)
        endif()
        return()
    endif()

    if("${DEP}" MATCHES "/")
        string(REPLACE "/" "_" _bare "${DEP}")
        # Split at the first '/' to distinguish two dep styles:
        #   FWCore/Utilities  — FWCore is a subsystem inside Stitched; full path is the target suffix
        #   Code4hep/PodioUtilities — Code4hep IS the project; remainder is the direct target name
        string(REGEX MATCH "^([^/]+)/(.+)$" _c4h_slash_match "${DEP}")
        set(_first_component "${CMAKE_MATCH_1}")
        set(_rest_path       "${CMAKE_MATCH_2}")
        string(REPLACE "/" "_" _rest_bare "${_rest_path}")

        get_property(_upstreams GLOBAL PROPERTY C4H_UPSTREAM_PROJECTS)
        foreach(_up IN LISTS _upstreams)
            string(TOLOWER "${_up}"              _up_lower)
            string(TOLOWER "${_first_component}" _first_lower)

            # Style A: subsystem-qualified — Upstream::First_Rest or Upstream::upstream_First_Rest
            # (e.g. FWCore/Utilities → Stitched::stitched_FWCore_Utilities)
            if(TARGET "${_up}::${_bare}")
                set(${OUT_VAR} "${_up}::${_bare}" PARENT_SCOPE)
                return()
            endif()
            if(TARGET "${_up}::${_up_lower}_${_bare}")
                set(${OUT_VAR} "${_up}::${_up_lower}_${_bare}" PARENT_SCOPE)
                return()
            endif()

            # Style B: project-qualified — first component IS the upstream project name.
            # (e.g. Code4hep/PodioUtilities with upstream Code4hep)
            # Installed package exposes Code4hep::PodioUtilities;
            # in-tree build exposes bare PodioUtilities.
            if("${_first_lower}" STREQUAL "${_up_lower}")
                if(TARGET "${_up}::${_rest_bare}")
                    # Installed: namespace-qualified target exists.
                    set(${OUT_VAR} "${_up}::${_rest_bare}" PARENT_SCOPE)
                    return()
                else()
                    # In-tree: accept bare name unconditionally; generator catches typos.
                    set(${OUT_VAR} "${_rest_bare}" PARENT_SCOPE)
                    return()
                endif()
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
# Internal helper: schedule c4h_auto_subdirectories() to run at the end of
# the CALLING directory's scope (not the function scope).
#
# Idempotent — the first c4h_add_* call in a CMakeLists.txt registers the
# deferred scan; subsequent calls in the same file are no-ops.
#
# Requires CMake 3.19+ (cmake_language DEFER), which is satisfied by the
# project's minimum of 3.23.
# ---------------------------------------------------------------------------
function(_c4h_defer_auto_subdirectories)
    get_property(_scheduled DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
                 PROPERTY _C4H_AUTO_SUBDIRS_SCHEDULED)
    if(NOT _scheduled)
        set_property(DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
                     PROPERTY _C4H_AUTO_SUBDIRS_SCHEDULED TRUE)
        cmake_language(DEFER CALL c4h_auto_subdirectories)
    endif()
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
#   NAME      Target/library name. Defaults to the directory-derived name.
#   SOURCES   Source glob patterns. Defaults to src/*.cc.
#   DEPS      Internal dependencies (shorthand, resolved to CMake targets).
#   EXT_DEPS  External dependencies (fully-qualified imported targets).
#
# All dependencies are linked PUBLIC. For anything beyond this — private
# linkage, extra include directories, raw -l flags, recursive globs, compile
# options — call the underlying CMake commands (target_link_libraries,
# target_include_directories, target_compile_options, …) on the target
# directly after c4h_add_library(); the target name is NAME or the derived
# name. Likewise, build a Debug/instrumented variant with
# cmake -DCMAKE_BUILD_TYPE=Debug rather than per-target flags here.
# ---------------------------------------------------------------------------
function(c4h_add_library)
    cmake_parse_arguments(C4H_LIB "" "NAME" "SOURCES;DEPS;EXT_DEPS" ${ARGN})
    _c4h_defer_auto_subdirectories()

    # --- Target name: NAME override, else derived from directory path ---
    _c4h_derive_target_name(_auto_target _pkg_path)
    if(C4H_LIB_NAME)
        set(_C4H_TARGET "${C4H_LIB_NAME}")
    else()
        set(_C4H_TARGET "${_auto_target}")
    endif()

    # --- Sources (SOURCES patterns, else src/*.cc) and public headers (*.h) ---
    if(C4H_LIB_SOURCES)
        set(_glob_patterns ${C4H_LIB_SOURCES})
    else()
        set(_glob_patterns "${CMAKE_CURRENT_SOURCE_DIR}/src/*.cc")
    endif()
    file(GLOB _sources CONFIGURE_DEPENDS ${_glob_patterns})
    file(GLOB _headers CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/*.h")

    add_library(${_C4H_TARGET} SHARED ${_sources})

    target_include_directories(${_C4H_TARGET}
        PUBLIC
            $<BUILD_INTERFACE:${CMAKE_SOURCE_DIR}>
            $<INSTALL_INTERFACE:include>
    )
    if(_headers)
        target_sources(${_C4H_TARGET}
            PUBLIC
            FILE_SET HEADERS
            BASE_DIRS "${CMAKE_SOURCE_DIR}"
            FILES ${_headers}
        )
    endif()

    # --- Dependencies (all PUBLIC). EXT_DEPS are fully-qualified imported
    # targets; resolving them triggers find_package() for their namespace. ---
    _c4h_resolve_deps("${C4H_LIB_DEPS}"     _pub_deps)
    _c4h_resolve_deps("${C4H_LIB_EXT_DEPS}" _ext_pub_deps)
    if(_pub_deps OR _ext_pub_deps)
        target_link_libraries(${_C4H_TARGET} PUBLIC ${_pub_deps} ${_ext_pub_deps})
    endif()

    # Fail the link if any symbol is unresolved (Linux).
    if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
        target_link_options(${_C4H_TARGET} PRIVATE "-Wl,--no-undefined")
    endif()

    string(REGEX MATCH "^[0-9]+" _C4H_MAJOR "${PROJECT_VERSION}")
    set_target_properties(${_C4H_TARGET} PROPERTIES
        VERSION   "${PROJECT_VERSION}"
        SOVERSION "${_C4H_MAJOR}"
    )

    set_property(GLOBAL APPEND PROPERTY C4H_ALL_SOURCES ${_sources})

    # --- Auto-detect ROOT dictionary (src/classes.h + src/classes_def.xml) ---
    if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/src/classes.h" AND
       EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/src/classes_def.xml")
        message(STATUS "c4h: Auto-detected ROOT dictionary for ${_C4H_TARGET}")
        c4h_generate_dictionary(
            TARGET  "${_C4H_TARGET}"
            HEADERS "${CMAKE_CURRENT_SOURCE_DIR}/src/classes.h"
            LINKDEF "${CMAKE_CURRENT_SOURCE_DIR}/src/classes_def.xml"
        )
    endif()

    install(TARGETS ${_C4H_TARGET}
        EXPORT  "${PROJECT_NAME}Targets"
        LIBRARY DESTINATION "${CMAKE_INSTALL_LIBDIR}"
        FILE_SET HEADERS
    )
endfunction()

# ---------------------------------------------------------------------------
# 2. c4h_add_plugin
#
# SCRAM equivalent: <library> with <flags EDM_PLUGIN="1"/>
# Wraps stitched_generate_plugin (edmWriteConfigs, modules.py, python/).
#
#   NAME      Plugin name. Defaults to the directory-derived name; the target
#             is plugin_<name>.
#   SOURCES   Source glob patterns. Defaults to *.cc when called from a
#             plugins/ directory, else plugins/*.cc.
#   DEPS      Internal dependencies (shorthand).
#   EXT_DEPS  External dependencies (fully-qualified imported targets).
#
# All dependencies are linked PUBLIC (stitched_generate_plugin links them so
# their include directories propagate). For anything more, operate on the
# plugin_<name> target directly after this call.
# ---------------------------------------------------------------------------
function(c4h_add_plugin)
    cmake_parse_arguments(C4H_PLG "" "NAME" "SOURCES;DEPS;EXT_DEPS" ${ARGN})
    _c4h_defer_auto_subdirectories()

    # --- Target name: NAME override, else directory-derived ---
    _c4h_derive_target_name(_auto_target _pkg_path)
    if(C4H_PLG_NAME)
        set(_plugin_name "${C4H_PLG_NAME}")
    else()
        set(_plugin_name "${_auto_target}")
    endif()
    set(_target "plugin_${_plugin_name}")

    # --- Sources: SOURCES patterns, else *.cc (in a plugins/ dir) or plugins/*.cc ---
    if(C4H_PLG_SOURCES)
        file(GLOB _sources CONFIGURE_DEPENDS ${C4H_PLG_SOURCES})
    else()
        get_filename_component(_curdir "${CMAKE_CURRENT_SOURCE_DIR}" NAME)
        if("${_curdir}" STREQUAL "plugins")
            file(GLOB _sources CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/*.cc")
        else()
            file(GLOB _sources CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/plugins/*.cc")
        endif()
    endif()

    _c4h_resolve_deps("${C4H_PLG_DEPS}"     _resolved_deps)
    _c4h_resolve_deps("${C4H_PLG_EXT_DEPS}" _resolved_ext_deps)

    # Delegate to Stitched. It adds $<BUILD_INTERFACE:${CMAKE_SOURCE_DIR}> and
    # links the libraries PUBLIC, so include dirs propagate without extra work.
    stitched_generate_plugin(
        TARGET         "${_target}"
        SOURCES        ${_sources}
        LINK_LIBRARIES ${_resolved_deps} ${_resolved_ext_deps}
    )

    # All plugin .so files must share one directory for edmPluginRefresh.
    set_target_properties(${_target} PROPERTIES
        LIBRARY_OUTPUT_DIRECTORY "${C4H_PLUGIN_OUTPUT_DIR}"
    )

    set_property(GLOBAL APPEND PROPERTY C4H_PLUGIN_TARGETS "${_target}")
    set_property(GLOBAL APPEND PROPERTY C4H_ALL_SOURCES ${_sources})
endfunction()

# ---------------------------------------------------------------------------
# 3. c4h_add_executable
#
# SCRAM equivalent: <bin name="..." file="...">
# Builds and installs a binary executable (target bin_<name>).
#
#   NAME      Executable name (required).
#   SOURCES   Source glob patterns. Defaults to bin/<name>.cc, else bin/*.cc.
#   DEPS      Internal dependencies (shorthand).
#   EXT_DEPS  External dependencies (fully-qualified imported targets).
# ---------------------------------------------------------------------------
function(c4h_add_executable)
    cmake_parse_arguments(C4H_EXE "" "NAME" "SOURCES;DEPS;EXT_DEPS" ${ARGN})
    _c4h_defer_auto_subdirectories()

    if(NOT C4H_EXE_NAME)
        message(FATAL_ERROR "c4h_add_executable: NAME is required.")
    endif()

    set(_target "bin_${C4H_EXE_NAME}")

    # --- Sources: SOURCES patterns, else bin/<name>.cc, else bin/*.cc ---
    if(C4H_EXE_SOURCES)
        file(GLOB _sources CONFIGURE_DEPENDS ${C4H_EXE_SOURCES})
    elseif(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/bin/${C4H_EXE_NAME}.cc")
        set(_sources "${CMAKE_CURRENT_SOURCE_DIR}/bin/${C4H_EXE_NAME}.cc")
    else()
        file(GLOB _sources CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/bin/*.cc")
    endif()

    add_executable(${_target} ${_sources})
    target_include_directories(${_target} PRIVATE
        $<BUILD_INTERFACE:${CMAKE_SOURCE_DIR}>
    )

    _c4h_resolve_deps("${C4H_EXE_DEPS}"     _resolved_deps)
    _c4h_resolve_deps("${C4H_EXE_EXT_DEPS}" _resolved_ext_deps)
    if(_resolved_deps OR _resolved_ext_deps)
        target_link_libraries(${_target} PRIVATE ${_resolved_deps} ${_resolved_ext_deps})
    endif()

    install(TARGETS ${_target}
        EXPORT  "${PROJECT_NAME}Targets"
        RUNTIME DESTINATION "${CMAKE_INSTALL_BINDIR}"
    )
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
    get_property(_plugin_targets GLOBAL PROPERTY C4H_PLUGIN_TARGETS)
    if(NOT _plugin_targets)
        message(FATAL_ERROR
            "c4h_generate_plugincache: No plugin targets registered. "
            "Ensure c4h_add_plugin() has been called before this function.")
    endif()

    # Delegates to Stitched: stitched_generate_plugincache in StitchedMacros.cmake.
    # The output directory must match the plugins' LIBRARY_OUTPUT_DIRECTORY.
    stitched_generate_plugincache(
        PLUGIN_TARGETS    ${_plugin_targets}
        OUTPUT_DIR        "${C4H_PLUGIN_OUTPUT_DIR}"
        CACHE_TARGET_NAME "RefreshPluginCache"
    )
endfunction()

# ---------------------------------------------------------------------------
# 5. c4h_add_test
#
# SCRAM equivalent: <test name="..." command="...">
# Registers a script-based test with CTest, run from the current source
# directory.
#
#   NAME     Test name (required).
#   COMMAND  Command to run (required). ${LOCALTOP} expands to CMAKE_SOURCE_DIR.
#   DEPS     Internal dependencies whose build directories are prepended to
#            LD_LIBRARY_PATH so the test finds in-tree libraries at runtime.
# ---------------------------------------------------------------------------
function(c4h_add_test)
    cmake_parse_arguments(C4H_TST "" "NAME" "COMMAND;DEPS" ${ARGN})

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

    add_test(NAME "${C4H_TST_NAME}"
        COMMAND ${_cmd}
        WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
    )

    # Prepend dependency build directories to LD_LIBRARY_PATH.
    _c4h_resolve_deps("${C4H_TST_DEPS}" _resolved_deps)
    set(_lib_dirs)
    foreach(_dep IN LISTS _resolved_deps)
        if(TARGET "${_dep}")
            list(APPEND _lib_dirs "$<TARGET_FILE_DIR:${_dep}>")
        endif()
    endforeach()
    if(_lib_dirs)
        string(JOIN ":" _lib_path_str ${_lib_dirs})
        set_tests_properties("${C4H_TST_NAME}" PROPERTIES
            ENVIRONMENT "LD_LIBRARY_PATH=${_lib_path_str}:\$ENV{LD_LIBRARY_PATH}")
    endif()

    # Package label for `ctest -L`.
    _c4h_derive_target_name(_auto _pkg_path)
    set_tests_properties("${C4H_TST_NAME}" PROPERTIES LABELS "${_pkg_path}")
endfunction()

# ---------------------------------------------------------------------------
# 6. c4h_generate_dictionary (internal helper, also callable directly)
#
# SCRAM equivalent: <flags LCG_DICT_HEADER="..." LCG_DICT_XML="..."/>
# Wraps stitched_generate_dictionary (StitchedMacros.cmake).
# Called automatically by c4h_add_library when dict files are detected.
# May also be called explicitly for packages needing multiple dictionaries.
# ---------------------------------------------------------------------------
function(c4h_generate_dictionary)
    cmake_parse_arguments(C4H_DICT "" "TARGET;HEADERS;LINKDEF" "" ${ARGN})

    if(NOT C4H_DICT_TARGET)
        message(FATAL_ERROR "c4h_generate_dictionary: TARGET is required.")
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
        OPTIONS --reflex
    )
endfunction()

# ---------------------------------------------------------------------------
# c4h_auto_subdirectories([EXCLUDE <dirs...>])
#
# Automatically calls add_subdirectory() for every direct child directory of
# CMAKE_CURRENT_SOURCE_DIR that contains a CMakeLists.txt.  Directories are
# processed in alphabetical order.
#
# Normally you do NOT need to call this function explicitly.  Any c4h_add_*
# call schedules it via cmake_language(DEFER) to run at the end of the
# enclosing CMakeLists.txt scope, so subdirectories are always picked up
# without any extra boilerplate.
#
# The only reason to call it explicitly is when EXCLUDE is needed to skip
# specific subdirectories, or in a purely structural CMakeLists.txt that has
# no c4h_add_* call of its own.
#
# EXCLUDE: directory names (not paths) to skip.  An explicit call with EXCLUDE
#          takes precedence over the automatically deferred call.
#
# Like source globbing, this uses a CONFIGURE_DEPENDS glob so CMake re-runs
# automatically when the directory's child list changes.
# ---------------------------------------------------------------------------
function(c4h_auto_subdirectories)
    cmake_parse_arguments(C4H_ASD "" "" "EXCLUDE" ${ARGN})

    # If already run explicitly in this directory, the deferred call (which
    # arrives with no arguments) is a no-op.
    get_property(_done DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
                 PROPERTY _C4H_AUTO_SUBDIRS_DONE)
    if(_done AND NOT C4H_ASD_EXCLUDE AND NOT C4H_ASD_UNPARSED_ARGUMENTS)
        # Deferred no-arg call after an explicit call already ran — skip.
        return()
    endif()
    set_property(DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
                 PROPERTY _C4H_AUTO_SUBDIRS_DONE TRUE)

    file(GLOB _children
        LIST_DIRECTORIES true
        CONFIGURE_DEPENDS
        RELATIVE "${CMAKE_CURRENT_SOURCE_DIR}"
        "${CMAKE_CURRENT_SOURCE_DIR}/*"
    )

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
            COMMENT "Running clang-format over all Code4hep sources"
        )
    else()
        message(STATUS "c4h: clang-format not found; 'format' target disabled.")
    endif()
endfunction()
