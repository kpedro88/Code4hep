cmake_minimum_required(VERSION 3.23)

project(Code4hep
    VERSION 1.0.0
    LANGUAGES CXX
)

# Set C++ standard (C++20 required for concepts)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

include(GNUInstallDirs)
include(CMakePackageConfigHelpers)

# Load the Code4hep build-helper functions (in-tree use).
# Downstream repos get these via find_package(Code4hep REQUIRED).
include("${CMAKE_SOURCE_DIR}/cmake/Code4hepBuildFunctions.cmake")

# Register Code4hep itself so that DEPS like Code4hep/PodioUtilities resolve
# correctly: in-tree to bare PodioUtilities, installed to Code4hep::PodioUtilities.
c4h_register_upstream(Code4hep)

# Stitched is the mandatory upstream framework.
# Its targets (Stitched::FWCore_*, etc.) are needed for DEPS shorthand resolution.
find_package(Stitched REQUIRED)
c4h_register_upstream(Stitched)

# Optional clang-tidy — enable with: cmake -DC4H_ENABLE_TIDY=ON
option(C4H_ENABLE_TIDY "Enable clang-tidy for all targets" OFF)
if(C4H_ENABLE_TIDY)
    find_program(CLANG_TIDY_EXECUTABLE clang-tidy REQUIRED)
    set(CMAKE_CXX_CLANG_TIDY "${CLANG_TIDY_EXECUTABLE}")
endif()

# enable_testing() must be called before any c4h_add_test* calls in subdirectories.
enable_testing()

# Descend into the inner Code4hep/ package directory.
# That file calls c4h_auto_subdirectories(), which picks up every package
# subdirectory that has a CMakeLists.txt — no manual listing needed.
add_subdirectory(Code4hep)

# Plugin cache refresh — after all subdirectories so C4H_PLUGIN_TARGETS is complete.
c4h_generate_plugincache()

# clang-format target — after all subdirectories so C4H_ALL_SOURCES is complete.
c4h_add_format_target()

# ---------------------------------------------------------------------------
# Install the CMake helper functions alongside this package's config so that
# downstream repos get c4h_* functions automatically via find_package(Code4hep).
# ---------------------------------------------------------------------------
install(FILES
    "${CMAKE_SOURCE_DIR}/cmake/Code4hepBuildFunctions.cmake"
    DESTINATION "${CMAKE_INSTALL_LIBDIR}/cmake/Code4hep"
)

configure_package_config_file(
    "${CMAKE_SOURCE_DIR}/cmake/Code4hepConfig.cmake.in"
    "${CMAKE_CURRENT_BINARY_DIR}/Code4hepConfig.cmake"
    INSTALL_DESTINATION "${CMAKE_INSTALL_LIBDIR}/cmake/Code4hep"
)
write_basic_package_version_file(
    "${CMAKE_CURRENT_BINARY_DIR}/Code4hepConfigVersion.cmake"
    VERSION "${PROJECT_VERSION}"
    COMPATIBILITY SameMajorVersion
)
install(FILES
    "${CMAKE_CURRENT_BINARY_DIR}/Code4hepConfig.cmake"
    "${CMAKE_CURRENT_BINARY_DIR}/Code4hepConfigVersion.cmake"
    DESTINATION "${CMAKE_INSTALL_LIBDIR}/cmake/Code4hep"
)

install(EXPORT Code4hepTargets
    FILE      Code4hepTargets.cmake
    NAMESPACE Code4hep::
    DESTINATION "${CMAKE_INSTALL_LIBDIR}/cmake/Code4hep"
)
