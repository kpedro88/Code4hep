cmake_minimum_required(VERSION 3.23)

project(code4hep
    VERSION 1.0.0
    LANGUAGES CXX
)

include(GNUInstallDirs)
include(CMakePackageConfigHelpers)

# Load the Code4HEP build-helper functions (in-tree use).
# Downstream repos get these via find_package(code4hep REQUIRED).
include("${CMAKE_SOURCE_DIR}/cmake/Code4HepBuildFunctions.cmake")

# stitched is the mandatory upstream framework.
# Its targets (stitched::FWCore_*, etc.) are needed for DEPS shorthand resolution.
find_package(stitched REQUIRED)
c4h_register_upstream(stitched)

# Optional clang-tidy — enable with: cmake -DC4H_ENABLE_TIDY=ON
option(C4H_ENABLE_TIDY "Enable clang-tidy for all targets" OFF)
if(C4H_ENABLE_TIDY)
    find_program(CLANG_TIDY_EXECUTABLE clang-tidy REQUIRED)
    set(CMAKE_CXX_CLANG_TIDY "${CLANG_TIDY_EXECUTABLE}")
endif()

# enable_testing() must be called before any c4h_add_test* calls in subdirectories.
enable_testing()

# Descend into the inner code4hep/ package directory.
# That file calls c4h_auto_subdirectories(), which picks up every package
# subdirectory that has a CMakeLists.txt — no manual listing needed.
add_subdirectory(code4hep)

# Plugin cache refresh — after all subdirectories so C4H_PLUGIN_TARGETS is complete.
c4h_generate_plugincache()

# clang-format target — after all subdirectories so C4H_ALL_SOURCES is complete.
c4h_add_format_target()

# ---------------------------------------------------------------------------
# Install the CMake helper functions alongside this package's config so that
# downstream repos get c4h_* functions automatically via find_package(code4hep).
# ---------------------------------------------------------------------------
install(FILES
    "${CMAKE_SOURCE_DIR}/cmake/Code4HepBuildFunctions.cmake"
    DESTINATION "${CMAKE_INSTALL_LIBDIR}/cmake/code4hep"
)

configure_package_config_file(
    "${CMAKE_SOURCE_DIR}/cmake/code4hepConfig.cmake.in"
    "${CMAKE_CURRENT_BINARY_DIR}/code4hepConfig.cmake"
    INSTALL_DESTINATION "${CMAKE_INSTALL_LIBDIR}/cmake/code4hep"
)
write_basic_package_version_file(
    "${CMAKE_CURRENT_BINARY_DIR}/code4hepConfigVersion.cmake"
    VERSION "${PROJECT_VERSION}"
    COMPATIBILITY SameMajorVersion
)
install(FILES
    "${CMAKE_CURRENT_BINARY_DIR}/code4hepConfig.cmake"
    "${CMAKE_CURRENT_BINARY_DIR}/code4hepConfigVersion.cmake"
    DESTINATION "${CMAKE_INSTALL_LIBDIR}/cmake/code4hep"
)

install(EXPORT code4hepTargets
    FILE      code4hepTargets.cmake
    NAMESPACE code4hep::
    DESTINATION "${CMAKE_INSTALL_LIBDIR}/cmake/code4hep"
)
