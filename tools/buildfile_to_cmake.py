#!/usr/bin/env python3
"""
buildfile_to_cmake.py — Convert SCRAM BuildFile.xml to CMakeLists.txt
using Code4HepBuild (c4h_*) CMake functions.

Usage:
    buildfile_to_cmake.py [OPTIONS] [BUILDFILE]
    buildfile_to_cmake.py --scan-dir DIR [OPTIONS]

Single-file mode:
    BUILDFILE           Path to BuildFile.xml. Defaults to ./BuildFile.xml.

Scan-dir mode (--scan-dir DIR):
    Recursively converts every BuildFile.xml found under DIR.  Also:
      - Generates mid-level structural CMakeLists.txt files (directories that
        contain no BuildFile.xml of their own but have package children) that
        call c4h_auto_subdirectories().
      - Appends c4h_auto_subdirectories() to any package CMakeLists.txt whose
        directory has direct child directories that also have a BuildFile.xml
        (e.g. DataFormats/ → DataFormats/plugins/).
      - Writes cmake/FindPackagesAuto.cmake listing all find_package() calls
        needed for external dependencies found across the whole tree.
        Include it from your top-level CMakeLists.txt with:
            include(cmake/FindPackagesAuto.cmake)

Options:
    -o, --output FILE   Output path. Defaults to CMakeLists.txt in the same
                        directory as BUILDFILE. Use '-' for stdout.
                        Ignored in --scan-dir mode.
    --scan-dir DIR      Convert all BuildFile.xml files under DIR (recursive).
    --cmake-dir DIR     Where to write FindPackagesAuto.cmake.
                        Defaults to <scan-dir>/../cmake/.
    --project NAME      The CMake project name (e.g. "code4hep"). Used only for
                        informational comments in the output; functions derive
                        target names automatically at CMake configure time.
    --dry-run           Print to stdout without writing any files.
    --map FILE          Path to a .py file containing a single bare Python dict
                        literal mapping additional SCRAM tool names to CMake
                        target name strings. The file is read with
                        ast.literal_eval — no imports, no expressions, just a
                        dict. Entries are merged over the built-in
                        SCRAM_TO_CMAKE_TARGETS table, with the file's entries
                        taking precedence. See tools/scram_cmake_map.py for the
                        format.
    --force             Overwrite existing CMakeLists.txt files without prompting.

Exit codes:
    0   Conversion successful (no unsupported features encountered).
    1   Conversion completed but unsupported features were found; the output
        contains # UNSUPPORTED: markers at the relevant positions. Review and
        edit the generated file before using it.
    2   Fatal error (unreadable input, bad map file, etc.).

Map file format:
    A .py file containing nothing but a bare Python dict literal, e.g.:
        {
            "myexternaltool": "MyExternalTool::MyExternalTool",
            "root": "ROOT::Core ROOT::RIO",
        }
    Read with ast.literal_eval; no imports or expressions are permitted.
"""

from __future__ import annotations

import argparse
import ast
import os
import pathlib
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from typing import Iterator, List, Optional, Tuple

# ---------------------------------------------------------------------------
# Built-in SCRAM tool name → CMake imported target mapping
# ---------------------------------------------------------------------------
SCRAM_TO_CMAKE_TARGETS: dict[str, str] = {
    "tbb":       "TBB::tbb",
    "rootcore":  "ROOT::Core",
    "root":      "ROOT::Core",
    "boost":     "Boost::boost",
    "eigen":     "Eigen3::Eigen",
    "clhep":     "CLHEP::CLHEP",
    "python3":   "Python3::Python",
    "xrootd":    "XROOTD::XROOTD",
    "sqlite":    "SQLite::SQLite3",
    "zlib":      "ZLIB::ZLIB",
    "bz2lib":    "BZip2::BZip2",
    "lzma":      "LibLZMA::LibLZMA",
    "openssl":   "OpenSSL::SSL",
    "podio":     "podio::podio",
    "edm4hep":   "EDM4HEP::edm4hep",
    "cmsswdata": "cmsswdata::cmsswdata",
    "json":      "nlohmann_json::nlohmann_json",
}

# ---------------------------------------------------------------------------
# SCRAM <if condition="..."> attribute → approximate CMake condition string
# ---------------------------------------------------------------------------
CONDITION_MAP: dict[str, str] = {
    "arch":        "CMAKE_SYSTEM_PROCESSOR MATCHES",   # value appended
    "compiler":    None,  # handled specially below
    "config":      None,  # handled specially below
    "cxx11_abi":   "CMAKE_CXX_STANDARD GREATER_EQUAL 11",
    "release":     "FALSE",
    "scram":       "FALSE",
    "project":     "FALSE",
}

# Flag names that trigger the unsupported-error format
UNSUPPORTED_FLAGS: frozenset[str] = frozenset({
    "SETENV_SCRIPT",
    "RIVET_PLUGIN",
})


# ---------------------------------------------------------------------------
# Node dataclasses
# ---------------------------------------------------------------------------

@dataclass
class BuildFileNode:
    tag: str
    line: int
    attrib: dict[str, str] = field(default_factory=dict)
    children: list = field(default_factory=list)


@dataclass
class UseNode(BuildFileNode):
    name: str = ""


@dataclass
class FlagsNode(BuildFileNode):
    pairs: dict[str, str] = field(default_factory=dict)


@dataclass
class IncludePathNode(BuildFileNode):
    path: str = ""


@dataclass
class ExportNode(BuildFileNode):
    has_lib: bool = False


@dataclass
class LibraryNode(BuildFileNode):
    name: str = ""
    file_patterns: list[str] = field(default_factory=list)
    uses: list[UseNode] = field(default_factory=list)
    flags: list[FlagsNode] = field(default_factory=list)
    include_paths: list[IncludePathNode] = field(default_factory=list)


@dataclass
class BinNode(BuildFileNode):
    name: str = ""
    file: str = ""
    uses: list[UseNode] = field(default_factory=list)
    include_paths: list[IncludePathNode] = field(default_factory=list)


@dataclass
class TestNode(BuildFileNode):
    name: str = ""
    command: str = ""
    uses: list[UseNode] = field(default_factory=list)
    flags: list[FlagsNode] = field(default_factory=list)


@dataclass
class IfNode(BuildFileNode):
    """
    Represents an <if>, <elif>, <else> chain.
    branches: list of (condition_str, children_list) tuples.
    """
    branches: list[tuple[str, list]] = field(default_factory=list)

# ---------------------------------------------------------------------------
# XML parser
# ---------------------------------------------------------------------------

def _lineno(elem: ET.Element) -> int:
    """Return the line number of an element if available."""
    return getattr(elem, "sourceline", 0)


def _iter_elements_with_line(path: str) -> Tuple[ET.ElementTree, dict]:
    """
    Parse XML and return (tree, elem_to_line) dict.
    Uses iterparse to capture line numbers.
    """
    elem_to_line: dict[int, int] = {}
    try:
        for event, elem in ET.iterparse(path, events=("start",)):
            elem_to_line[id(elem)] = getattr(elem, "sourceline",
                                             getattr(elem, "_start_line_number", 0))
    except AttributeError:
        pass
    tree = ET.parse(path)
    return tree, elem_to_line


def parse_buildfile(path: str) -> list[BuildFileNode]:
    """
    Parse a SCRAM BuildFile.xml and return a list of top-level BuildFileNode instances.
    """
    try:
        tree = ET.parse(path)
    except ET.ParseError as exc:
        print(f"ERROR: Cannot parse XML in '{path}': {exc}", file=sys.stderr)
        sys.exit(2)

    root = tree.getroot()
    nodes: list[BuildFileNode] = []
    _parse_children(root, nodes, path)
    return nodes


def _get_line(elem: ET.Element) -> int:
    # ElementTree doesn't expose line numbers by default; best-effort.
    return 0


def _parse_children(parent: ET.Element, out: list, filepath: str) -> None:
    """Recursively parse child elements of parent into BuildFileNode instances."""
    for elem in parent:
        node = _parse_element(elem, filepath)
        if node is not None:
            out.append(node)


def _parse_element(elem: ET.Element, filepath: str) -> Optional[BuildFileNode]:
    tag = elem.tag.lower()
    line = _get_line(elem)

    if tag == "use":
        n = UseNode(tag="use", line=line, attrib=dict(elem.attrib))
        n.name = elem.attrib.get("name", "")
        return n

    if tag == "flags":
        n = FlagsNode(tag="flags", line=line, attrib=dict(elem.attrib))
        n.pairs = {k: v for k, v in elem.attrib.items()}
        return n

    if tag == "include_path":
        n = IncludePathNode(tag="include_path", line=line, attrib=dict(elem.attrib))
        n.path = elem.attrib.get("path", "")
        return n

    if tag == "export":
        n = ExportNode(tag="export", line=line, attrib=dict(elem.attrib))
        for child in elem:
            if child.tag.lower() == "lib":
                if child.attrib.get("name") == "1":
                    n.has_lib = True
        return n

    if tag == "library":
        n = LibraryNode(tag="library", line=line, attrib=dict(elem.attrib))
        n.name = elem.attrib.get("name", "")
        raw_file = elem.attrib.get("file", "")
        if raw_file:
            n.file_patterns = [p.strip() for p in raw_file.split(",") if p.strip()]
        for child in elem:
            child_node = _parse_element(child, filepath)
            if isinstance(child_node, UseNode):
                n.uses.append(child_node)
            elif isinstance(child_node, FlagsNode):
                n.flags.append(child_node)
            elif isinstance(child_node, IncludePathNode):
                n.include_paths.append(child_node)
        return n

    if tag == "bin":
        n = BinNode(tag="bin", line=line, attrib=dict(elem.attrib))
        n.name = elem.attrib.get("name", "")
        n.file = elem.attrib.get("file", "")
        for child in elem:
            child_node = _parse_element(child, filepath)
            if isinstance(child_node, UseNode):
                n.uses.append(child_node)
            elif isinstance(child_node, IncludePathNode):
                n.include_paths.append(child_node)
        return n

    if tag == "test":
        n = TestNode(tag="test", line=line, attrib=dict(elem.attrib))
        n.name = elem.attrib.get("name", "")
        n.command = elem.attrib.get("command", "")
        for child in elem:
            child_node = _parse_element(child, filepath)
            if isinstance(child_node, UseNode):
                n.uses.append(child_node)
            elif isinstance(child_node, FlagsNode):
                n.flags.append(child_node)
        return n

    if tag in ("if", "elif", "else"):
        return _parse_if_chain(elem, filepath)

    # Unknown element — will be handled by converter as unsupported
    n = BuildFileNode(tag=tag, line=line, attrib=dict(elem.attrib))
    _parse_children(elem, n.children, filepath)
    return n


def _parse_if_chain(elem: ET.Element, filepath: str) -> IfNode:
    """
    Parse an <if [elif] [else]> element chain.
    Collects (condition_attrib_str, children) tuples for each branch.
    """
    node = IfNode(tag="if", line=_get_line(elem), attrib=dict(elem.attrib))

    # Build condition string from all attributes (excluding standard XML ones)
    def _cond_str(e: ET.Element) -> str:
        return " ".join(f'{k}="{v}"' for k, v in e.attrib.items())

    branch_children: list[BuildFileNode] = []
    _parse_children(elem, branch_children, filepath)
    node.branches.append((_cond_str(elem), branch_children))

    # Note: in BuildFile.xml, elif/else are siblings, not children.
    # They will be encountered as separate top-level elements.
    # We model them as a single IfNode; the converter handles the chain.
    return node

# ---------------------------------------------------------------------------
# Converter context
# ---------------------------------------------------------------------------

@dataclass
class ConvertContext:
    filepath: str
    project_name: str
    target_map: dict[str, str]  # merged SCRAM_TO_CMAKE_TARGETS + --map overrides
    errors: list[str] = field(default_factory=list)

    def unsupported(self, feature: str, explanation: str, line: int = 0) -> str:
        loc = f"{self.filepath}:{line}" if line else self.filepath
        msg = (
            f"ERROR: Unsupported SCRAM feature '{feature}' in {loc}. "
            f"{explanation}. This feature must be handled manually."
        )
        print(msg, file=sys.stderr)
        self.errors.append(msg)
        return f"# UNSUPPORTED: {feature} — {explanation}. Manual intervention required."

    def resolve_ext_dep(self, scram_name: str, line: int = 0) -> tuple[str, bool]:
        """
        Resolve a SCRAM external tool name to a CMake target string.
        Returns (cmake_target_or_placeholder, is_known).
        """
        key = scram_name.lower()
        if key in self.target_map:
            return self.target_map[key], True
        return scram_name, False

# ---------------------------------------------------------------------------
# Dependency classifier
# ---------------------------------------------------------------------------

def _classify_dep(name: str) -> str:
    """Return 'internal' if name contains '/', else 'external'."""
    return "internal" if "/" in name else "external"

# ---------------------------------------------------------------------------
# Flags collector
# ---------------------------------------------------------------------------

def _collect_flags(flags_list: list[FlagsNode]) -> dict[str, str]:
    """Merge all FlagsNode pairs into a single dict."""
    merged: dict[str, str] = {}
    for fn in flags_list:
        merged.update(fn.pairs)
    return merged

# ---------------------------------------------------------------------------
# CMake condition translator
# ---------------------------------------------------------------------------

def _translate_condition(attrib_str: str, ctx: ConvertContext, line: int) -> tuple[str, list[str]]:
    """
    Translate a SCRAM <if> attribute string to a CMake condition expression.
    Returns (cmake_condition_string, list_of_warning_comments).
    """
    warnings: list[str] = []
    # Parse key="value" pairs from the attribute string
    import re
    pairs = re.findall(r'(\w+)="([^"]*)"', attrib_str)
    if not pairs:
        unsup = ctx.unsupported(
            f"if condition='{attrib_str}'",
            f"SCRAM condition attribute '{attrib_str}' has no known CMake equivalent; condition replaced with FALSE",
            line,
        )
        return "FALSE", [unsup]

    conditions: list[str] = []
    for key, value in pairs:
        key_lower = key.lower()
        if key_lower == "arch":
            conditions.append(f'CMAKE_SYSTEM_PROCESSOR MATCHES "{value}"')
        elif key_lower == "compiler":
            if value.startswith("gcc"):
                conditions.append('CMAKE_CXX_COMPILER_ID STREQUAL "GNU"')
            elif value.startswith("clang"):
                conditions.append('CMAKE_CXX_COMPILER_ID STREQUAL "Clang"')
            else:
                unsup = ctx.unsupported(
                    f"compiler={value}",
                    f"SCRAM condition attribute 'compiler={value}' has no known CMake equivalent; condition replaced with FALSE",
                    line,
                )
                conditions.append("FALSE")
                warnings.append(unsup)
        elif key_lower == "config":
            if value == "debug":
                conditions.append('CMAKE_BUILD_TYPE STREQUAL "Debug"')
            else:
                unsup = ctx.unsupported(
                    f"config={value}",
                    f"SCRAM condition attribute 'config={value}' has no known CMake equivalent; condition replaced with FALSE",
                    line,
                )
                conditions.append("FALSE")
                warnings.append(unsup)
        elif key_lower == "cxx11_abi":
            conditions.append("CMAKE_CXX_STANDARD GREATER_EQUAL 11")
        elif key_lower in ("release", "scram", "project"):
            unsup = ctx.unsupported(
                f"{key}={value}",
                f"SCRAM condition attribute '{key}={value}' has no known CMake equivalent; condition replaced with FALSE",
                line,
            )
            conditions.append("FALSE")
            warnings.append(unsup)
        else:
            unsup = ctx.unsupported(
                f"{key}={value}",
                f"SCRAM condition attribute '{key}={value}' has no known CMake equivalent; condition replaced with FALSE",
                line,
            )
            conditions.append("FALSE")
            warnings.append(unsup)

    cmake_cond = " AND ".join(conditions) if conditions else "FALSE"
    return cmake_cond, warnings

# ---------------------------------------------------------------------------
# Individual element converters
# ---------------------------------------------------------------------------

def _uses_to_deps(
    uses: list[UseNode],
    ctx: ConvertContext,
    line: int = 0,
) -> tuple[list[str], list[str], list[str]]:
    """
    Classify UseNode list into (internal_deps, external_deps, warning_lines).

    internal_deps: DEPS values — names containing '/', or single-component names
                   not found in the external tool map (same-repo build targets).
    external_deps: EXT_DEPS CMake target strings — single-component names that
                   resolve in the SCRAM_TO_CMAKE_TARGETS map.
    warning_lines: comment lines for truly unknown single-component names that
                   could not be resolved and were already treated as internal.

    The heuristic for ambiguous single-component names (no '/'):
      - If the lowercased name is in the target map → external tool (EXT_DEP).
      - If not in the map → assume a same-repo build-tree target (DEPS).
        SCRAM external tool names are consistently lowercase; package names are
        CamelCase, so false-positives in either direction are rare in practice.
    """
    internal: list[str] = []
    external: list[str] = []
    warnings: list[str] = []

    for use in uses:
        if "/" in use.name:
            # Two-component path — unambiguously an internal cross-package dep
            internal.append(use.name)
        else:
            cmake_target, known = ctx.resolve_ext_dep(use.name, line)
            if known:
                # Found in the external tool map — EXT_DEP
                external.append(cmake_target)
            else:
                # Not in the map — treat as a same-repo bare build-tree target
                internal.append(use.name)

    return internal, external, warnings


def _format_c4h_call(
    func: str,
    args: list[tuple[str, list[str] | str | None]],
    comment: str = "",
) -> list[str]:
    """
    Format a c4h_* function call.
    args: list of (keyword, value_or_values) where value_or_values is:
      - None: keyword-only flag (no value)
      - str:  single value
      - list: multi-value list
    Returns list of lines.
    """
    lines: list[str] = []
    if comment:
        lines.append(f"# {comment}")
    lines.append(f"{func}(")
    for kw, val in args:
        if val is None:
            lines.append(f"    {kw}")
        elif isinstance(val, str):
            lines.append(f"    {kw} {val}")
        else:
            if len(val) == 1:
                lines.append(f"    {kw} {val[0]}")
            else:
                lines.append(f"    {kw}")
                for v in val:
                    lines.append(f"        {v}")
    lines.append(")")
    return lines


def _convert_library(node: LibraryNode, ctx: ConvertContext,
                     top_include_paths: list[str]) -> list[str]:
    """Convert a <library> element."""
    flags = _collect_flags(node.flags)
    is_plugin = (
        flags.get("EDM_PLUGIN", "0") == "1"
        or flags.get("EDM_PLUGIN", "") == "1"
    )

    internal_deps, external_deps, dep_warnings = _uses_to_deps(node.uses, ctx, node.line)

    include_dirs = [ip.path for ip in node.include_paths] + top_include_paths

    out: list[str] = []
    out.extend(dep_warnings)

    # Build element comment
    file_attr = ", ".join(node.file_patterns)
    edm_note = " (EDM_PLUGIN=1)" if is_plugin else ""
    elem_comment = f'<library name="{node.name}" file="{file_attr}">{edm_note}'

    if is_plugin:
        args: list[tuple[str, list[str] | str | None]] = [
            ("NAME", node.name),
        ]
        if node.file_patterns:
            args.append(("SOURCES", node.file_patterns))
        if internal_deps:
            args.append(("DEPS", internal_deps))
        if external_deps:
            args.append(("EXT_DEPS", external_deps))
        if include_dirs:
            args.append(("INCLUDE_DIRS", include_dirs))
        out.extend(_format_c4h_call("c4h_add_plugin", args, comment=elem_comment))
    else:
        args = []
        if node.name:
            # Only emit NAME if it differs from auto-derived (we always emit for safety)
            args.append(("NAME", node.name))
        if node.file_patterns:
            sources = node.file_patterns
            args.append(("SOURCES", sources))
        if flags.get("RECURSE_SOURCES") == "1" or flags.get("ADD_SUBDIR") == "1":
            args.append(("RECURSE_SOURCES", None))
        skip = flags.get("SKIP_FILES", "")
        if skip:
            args.append(("EXCLUDE_SOURCES", skip.split()))
        dict_header = flags.get("LCG_DICT_HEADER", "")
        if dict_header:
            args.append(("DICT_HEADER", dict_header))
        dict_xml = flags.get("LCG_DICT_XML", "")
        if dict_xml:
            args.append(("DICT_XML", dict_xml))
        if flags.get("NO_LIB_CHECKING") == "1":
            args.append(("NO_SYMBOL_CHECK", None))
        install_scripts = flags.get("INSTALL_SCRIPTS", "")
        if install_scripts:
            args.append(("INSTALL_SCRIPTS", install_scripts.split()))
        if internal_deps:
            args.append(("DEPS", internal_deps))
        if external_deps:
            args.append(("EXT_DEPS", external_deps))
        if include_dirs:
            args.append(("INCLUDE_DIRS", include_dirs))
        out.extend(_format_c4h_call("c4h_add_library", args, comment=elem_comment))

    # Handle remaining flags
    for flag_name, flag_val in flags.items():
        if flag_name in UNSUPPORTED_FLAGS:
            out.append(ctx.unsupported(
                flag_name,
                _unsupported_explanation(flag_name),
                node.line,
            ))
        elif flag_name == "ROOTMAP" and flag_val == "1":
            out.append(
                "# NOTE: ROOTMAP=1 — add OPTIONS --rootmap to "
                "c4h_generate_dictionary if needed"
            )
        elif flag_name == "GENREFLEX_FAILS_ON_WARNS" and flag_val == "1":
            out.append(
                "# WARNING: GENREFLEX_FAILS_ON_WARNS=1 is not supported "
                "by Code4HepBuild."
            )
        elif flag_name == "TEST_RUNNER_CMD":
            out.append(
                "# WARNING: TEST_RUNNER_CMD replaces the entire test command; "
                "set COMMAND in c4h_add_test manually."
            )
        elif flag_name == "DROP_DEP":
            out.append(f"# WARNING: DROP_DEP={flag_val} is not supported.")
        elif flag_name == "LLVM_PLUGIN":
            out.append(f"# WARNING: LLVM_PLUGIN={flag_val} is not supported.")
        elif flag_name == "LLVM_CHECKERS":
            out.append(f"# WARNING: LLVM_CHECKERS={flag_val} is not supported.")
        # EDM_PLUGIN, ADD_SUBDIR, SKIP_FILES, LCG_DICT_*, NO_LIB_CHECKING,
        # INSTALL_SCRIPTS, RECURSE_SOURCES already handled above.

    return out


def _convert_bin(node: BinNode, ctx: ConvertContext,
                 top_include_paths: list[str]) -> list[str]:
    """Convert a <bin> element."""
    internal_deps, external_deps, dep_warnings = _uses_to_deps(node.uses, ctx, node.line)
    include_dirs = [ip.path for ip in node.include_paths] + top_include_paths

    elem_comment = f'<bin name="{node.name}" file="{node.file}">'
    args: list[tuple[str, list[str] | str | None]] = [("NAME", node.name)]
    if node.file:
        args.append(("SOURCES", [node.file]))
    if internal_deps:
        args.append(("DEPS", internal_deps))
    if external_deps:
        args.append(("EXT_DEPS", external_deps))
    if include_dirs:
        args.append(("INCLUDE_DIRS", include_dirs))

    out = list(dep_warnings)
    out.extend(_format_c4h_call("c4h_add_executable", args, comment=elem_comment))
    return out


def _convert_test(node: TestNode, ctx: ConvertContext) -> list[str]:
    """Convert a <test> element."""
    internal_deps, external_deps, dep_warnings = _uses_to_deps(node.uses, ctx, node.line)
    flags = _collect_flags(node.flags)

    cmd = node.command
    localtop_comment = ""
    if "${LOCALTOP}" in cmd:
        cmd = cmd.replace("${LOCALTOP}", "${CMAKE_SOURCE_DIR}")
        localtop_comment = "# NOTE: ${LOCALTOP} substituted with ${CMAKE_SOURCE_DIR}"

    # TEST_RUNNER_ARGS: append to command
    runner_args = flags.get("TEST_RUNNER_ARGS", "")
    if runner_args:
        cmd = cmd + " " + runner_args

    env_pairs: list[str] = []
    setenv = flags.get("SETENV", "")
    if setenv:
        env_pairs.append(setenv)

    depends: list[str] = []
    pre_test = flags.get("PRE_TEST", "")
    if pre_test:
        depends.append(pre_test)

    elem_comment = f'<test name="{node.name}" command="{node.command}">'
    args: list[tuple[str, list[str] | str | None]] = [
        ("NAME", node.name),
        ("COMMAND", [cmd] if " " not in cmd else cmd.split()),
    ]
    if internal_deps:
        args.append(("DEPS", internal_deps))
    if external_deps:
        args.append(("EXT_DEPS", external_deps))
    if env_pairs:
        args.append(("ENVIRONMENT", env_pairs))
    if depends:
        args.append(("DEPENDS", depends))

    out = list(dep_warnings)
    if localtop_comment:
        out.append(localtop_comment)

    # Check for unsupported flags
    for flag_name in UNSUPPORTED_FLAGS:
        if flag_name in flags:
            out.append(ctx.unsupported(
                flag_name,
                _unsupported_explanation(flag_name),
                node.line,
            ))
    if flags.get("TEST_RUNNER_CMD"):
        out.append(
            "# WARNING: TEST_RUNNER_CMD replaces the entire test command; "
            "set COMMAND in c4h_add_test manually."
        )

    out.extend(_format_c4h_call("c4h_add_test", args, comment=elem_comment))
    return out


def _unsupported_explanation(flag_name: str) -> str:
    if flag_name == "RIVET_PLUGIN":
        return "RIVET plugin generation is not yet supported by Code4HepBuild"
    if flag_name == "SETENV_SCRIPT":
        return (
            "Sourcing an environment script before tests has no direct CMake "
            "equivalent. Refactor to use explicit ENVIRONMENT entries or bake "
            "the values into the test command"
        )
    return f"Unrecognised SCRAM element/flag '{flag_name}'"


def _convert_if(node: IfNode, ctx: ConvertContext,
                top_include_paths: list[str]) -> list[str]:
    """Convert an <if> / <elif> / <else> chain."""
    out: list[str] = []
    for i, (cond_str, children) in enumerate(node.branches):
        cmake_cond, warnings = _translate_condition(cond_str, ctx, node.line)
        out.extend(warnings)
        if cond_str:
            out.append(
                f"# NOTE: SCRAM condition '{cond_str}' approximately translated"
            )
        if i == 0:
            out.append(f"if({cmake_cond})")
        elif cond_str:
            out.append(f"elseif({cmake_cond})")
        else:
            out.append("else()")

        for child in children:
            child_lines = _convert_node(child, ctx, top_include_paths)
            out.extend("    " + ln for ln in child_lines)

    out.append("endif()")
    return out


def _convert_node(
    node: BuildFileNode,
    ctx: ConvertContext,
    top_include_paths: list[str],
) -> list[str]:
    """Dispatch a single BuildFileNode to the appropriate converter."""
    if isinstance(node, LibraryNode):
        return _convert_library(node, ctx, top_include_paths)
    if isinstance(node, BinNode):
        return _convert_bin(node, ctx, top_include_paths)
    if isinstance(node, TestNode):
        return _convert_test(node, ctx)
    if isinstance(node, IfNode):
        return _convert_if(node, ctx, top_include_paths)
    if isinstance(node, (UseNode, FlagsNode, IncludePathNode, ExportNode)):
        # These are handled at the top level by convert(); skip here.
        return []
    # Unknown element
    msg = ctx.unsupported(
        node.tag,
        f"Unrecognised SCRAM element/flag '{node.tag}'",
        node.line,
    )
    return [msg]

# ---------------------------------------------------------------------------
# Top-level converter
# ---------------------------------------------------------------------------

def convert(nodes: list[BuildFileNode], ctx: ConvertContext) -> list[str]:
    """
    Convert a list of BuildFileNodes into CMake statement strings.
    Handles top-level <use> + <export> as a single c4h_add_library call.
    """
    statements: list[str] = []

    # Collect top-level uses, export, and include_paths
    top_uses: list[UseNode] = []
    top_export: Optional[ExportNode] = None
    top_include_paths: list[str] = []
    top_flags: list[FlagsNode] = []

    for node in nodes:
        if isinstance(node, UseNode):
            top_uses.append(node)
        elif isinstance(node, ExportNode):
            top_export = node
        elif isinstance(node, IncludePathNode):
            top_include_paths.append(node.path)
        elif isinstance(node, FlagsNode):
            top_flags.append(node)

    if top_include_paths:
        statements.append(
            "# NOTE: top-level <include_path> elements apply to all targets in this file."
        )

    # Determine if this is a standard library package
    has_explicit_library = any(isinstance(n, LibraryNode) for n in nodes)
    has_bin = any(isinstance(n, BinNode) for n in nodes)

    if top_uses and not has_explicit_library:
        # Always resolve deps so ext_targets_seen is populated (needed for --scan-dir
        # find_package generation even for header-only packages).
        internal_deps, external_deps, dep_warnings = _uses_to_deps(top_uses, ctx)

        if top_export and top_export.has_lib:
            # Standard linkable library
            statements.extend(dep_warnings)
            flags = _collect_flags(top_flags)

            args: list[tuple[str, list[str] | str | None]] = []
            if flags.get("ADD_SUBDIR") == "1":
                args.append(("RECURSE_SOURCES", None))
            skip = flags.get("SKIP_FILES", "")
            if skip:
                args.append(("EXCLUDE_SOURCES", skip.split()))
            dict_header = flags.get("LCG_DICT_HEADER", "")
            if dict_header:
                args.append(("DICT_HEADER", dict_header))
            dict_xml = flags.get("LCG_DICT_XML", "")
            if dict_xml:
                args.append(("DICT_XML", dict_xml))
            if flags.get("NO_LIB_CHECKING") == "1":
                args.append(("NO_SYMBOL_CHECK", None))
            install_scripts = flags.get("INSTALL_SCRIPTS", "")
            if install_scripts:
                args.append(("INSTALL_SCRIPTS", install_scripts.split()))
            if internal_deps:
                args.append(("DEPS", internal_deps))
            if external_deps:
                args.append(("EXT_DEPS", external_deps))
            if top_include_paths:
                args.append(("INCLUDE_DIRS", top_include_paths))

            statements.extend(_format_c4h_call(
                "c4h_add_library", args,
                comment="top-level <use> + <export><lib name=\"1\"/> — standard library package"
            ))
        else:
            # Header-only package — no CMake target, but deps are still recorded
            # in ext_targets_seen for find_package generation in --scan-dir mode.
            statements.append(
                "# Header-only package: no library target generated."
            )
            statements.append(
                "# Add include path to consumers via target_include_directories if needed."
            )

    # Convert remaining (non-use, non-export, non-include_path) nodes
    for node in nodes:
        if isinstance(node, (UseNode, ExportNode, IncludePathNode, FlagsNode)):
            continue  # already handled above

        stmts = _convert_node(node, ctx, top_include_paths)
        if stmts:
            statements.append("")  # blank line between calls
            statements.extend(stmts)

    return statements

# ---------------------------------------------------------------------------
# Renderer
# ---------------------------------------------------------------------------

def render(statements: list[str], source_path: str) -> str:
    """
    Render a list of statement strings to final CMakeLists.txt text.
    Adds the required header comment.
    """
    lines: list[str] = [
        "# Auto-generated by buildfile_to_cmake.py from BuildFile.xml. "
        "Review before committing.",
        "",
    ]
    lines.extend(statements)
    # Ensure trailing newline
    text = "\n".join(lines)
    if not text.endswith("\n"):
        text += "\n"
    return text

# ---------------------------------------------------------------------------
# Map file loader
# ---------------------------------------------------------------------------

def load_map_file(path: str) -> dict[str, str]:
    """
    Load a SCRAM-to-CMake target override map from a .py file.
    The file must contain only a bare Python dict literal.
    Uses ast.literal_eval — no imports or expressions permitted.
    """
    try:
        content = pathlib.Path(path).read_text(encoding="utf-8")
    except OSError as exc:
        print(f"ERROR: Cannot read map file '{path}': {exc}", file=sys.stderr)
        sys.exit(2)
    try:
        result = ast.literal_eval(content)
    except (ValueError, SyntaxError) as exc:
        print(
            f"ERROR: Map file '{path}' is not a valid Python dict literal: {exc}",
            file=sys.stderr,
        )
        sys.exit(2)
    if not isinstance(result, dict):
        print(
            f"ERROR: Map file '{path}' must contain a dict literal, "
            f"got {type(result).__name__}.",
            file=sys.stderr,
        )
        sys.exit(2)
    return {str(k): str(v) for k, v in result.items()}

# ---------------------------------------------------------------------------
# Directory scanner
# ---------------------------------------------------------------------------

def scan_directory(
    scan_root: pathlib.Path,
    target_map: dict[str, str],
    project_name: str,
    dry_run: bool,
    force: bool,
) -> int:
    """
    Walk scan_root recursively, converting every BuildFile.xml found.

    Also generates structural CMakeLists.txt files — for directories that sit
    between the scan root and the package leaves but have no BuildFile.xml of
    their own — including scan_root itself.  Every structural file calls
    c4h_auto_subdirectories(), which handles arbitrary nesting depths without
    any further intervention from the scan.

    Package files get c4h_auto_subdirectories() appended when any of their
    direct child directories also contain a BuildFile.xml (e.g. plugins/).

    find_package() calls are NOT generated here; they are handled automatically
    at CMake configure time by c4h_auto_find_package() inside the CMake
    helper functions.

    Returns 1 if any unsupported features were found, 0 otherwise.
    """
    ctx = ConvertContext(
        filepath="",
        project_name=project_name,
        target_map=target_map,
    )

    # --- Discover all BuildFile.xml paths ---
    buildfiles: list[pathlib.Path] = sorted(scan_root.rglob("BuildFile.xml"))

    if not buildfiles:
        print(f"WARNING: No BuildFile.xml found under '{scan_root}'.", file=sys.stderr)
        return 0

    scan_root_resolved = scan_root.resolve()

    # Set of resolved directories that own a BuildFile.xml
    package_dirs: set[pathlib.Path] = {bf.parent.resolve() for bf in buildfiles}

    # --- Collect all ancestor directories between scan_root and each package,
    #     that do NOT own a BuildFile.xml themselves.  These need structural files.
    #     Include scan_root itself — it is the inner repo directory (e.g. code4hep/)
    #     and needs a CMakeLists.txt that calls c4h_auto_subdirectories().
    structural_dirs: set[pathlib.Path] = set()
    for pkg_dir in package_dirs:
        current = pkg_dir.parent.resolve()
        while True:
            if current not in package_dirs:
                structural_dirs.add(current)
            if current == scan_root_resolved:
                break
            # Safety: don't climb above scan_root
            if scan_root_resolved not in current.parents:
                break
            current = current.parent

    # --- For each package dir, check whether any direct child directory also
    #     owns a BuildFile.xml (e.g. DataFormats/plugins/).
    def _direct_package_children(d: pathlib.Path) -> list[pathlib.Path]:
        return sorted(p for p in package_dirs if p.parent.resolve() == d.resolve())

    # --- Convert each BuildFile.xml ---
    any_errors = False
    for bf in buildfiles:
        ctx.filepath = str(bf)
        nodes = parse_buildfile(str(bf))
        statements = convert(nodes, ctx)

        if _direct_package_children(bf.parent):
            statements.append("")
            statements.append(
                "# Subdirectories with their own CMakeLists.txt are picked up automatically."
            )
            statements.append("c4h_auto_subdirectories()")

        output_text = render(statements, str(bf))
        out_path = bf.parent / "CMakeLists.txt"
        _write_file(out_path, output_text, dry_run, force,
                    label=str(bf.relative_to(scan_root_resolved.parent)))

        if ctx.errors:
            any_errors = True
            ctx.errors.clear()

    # --- Generate structural CMakeLists.txt files ---
    _STRUCTURAL_CONTENT = (
        "# Auto-generated by buildfile_to_cmake.py --scan-dir.\n"
        "# This directory has no BuildFile.xml of its own; it wires together\n"
        "# package subdirectories.  c4h_auto_subdirectories() picks them up\n"
        "# automatically at any nesting depth.\n"
        "c4h_auto_subdirectories()\n"
    )
    for struct_dir in sorted(structural_dirs):
        out_path = struct_dir / "CMakeLists.txt"
        _write_file(out_path, _STRUCTURAL_CONTENT, dry_run, force,
                    label=str(struct_dir.relative_to(scan_root_resolved.parent)))

    return 1 if any_errors else 0


def _write_file(
    path: pathlib.Path,
    content: str,
    dry_run: bool,
    force: bool,
    label: str = "",
) -> None:
    """Write content to path, respecting dry_run and force flags."""
    display = label or str(path)
    if dry_run:
        print(f"# --- {display} ---")
        print(content)
        return
    if path.exists() and not force:
        answer = input(f"'{path}' already exists. Overwrite? [y/N] ").strip().lower()
        if answer not in ("y", "yes"):
            print(f"Skipped '{display}'.", file=sys.stderr)
            return
    path.write_text(content, encoding="utf-8")
    print(f"Written: {display}", file=sys.stderr)


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        prog="buildfile_to_cmake.py",
        description=(
            "Convert a SCRAM BuildFile.xml to a CMakeLists.txt that uses "
            "the Code4HepBuild (c4h_*) CMake functions.  Run on a single file "
            "or use --scan-dir to convert an entire package tree at once."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Scan-dir mode (--scan-dir DIR):
  Converts every BuildFile.xml found recursively under DIR.  Additionally:
    - Generates mid-level structural CMakeLists.txt files for directories that
      have package children but no BuildFile.xml of their own (including the
      scan-root directory itself).  Each calls c4h_auto_subdirectories(), which
      handles arbitrary nesting depth without further intervention.
    - Appends c4h_auto_subdirectories() to any package CMakeLists.txt whose
      directory has direct child directories that also contain a BuildFile.xml
      (e.g. DataFormats/ whose plugins/ subdirectory has its own BuildFile.xml).
  find_package() calls are NOT generated; external dependencies are found
  automatically at CMake configure time by the c4h_auto_find_package()
  mechanism built into Code4HepBuildFunctions.cmake.

Map file format:
  A .py file containing a bare Python dict literal mapping SCRAM tool names
  (lowercase) to CMake imported-target strings.  Example:
      {
          "myexternaltool": "MyExternalTool::MyExternalTool",
          "root": "ROOT::Core ROOT::RIO",   # override to add ROOT::RIO
      }
  The file is read with ast.literal_eval — no imports or expressions allowed.
  See tools/scram_cmake_map.py for a complete example.

Exit codes:
  0   Conversion successful (no unsupported features).
  1   Conversion completed with unsupported features. The output contains
      # UNSUPPORTED: markers at the relevant positions. Review before use.
  2   Fatal error (unreadable input, bad map file, etc.).
""",
    )

    parser.add_argument(
        "buildfile",
        nargs="?",
        default=None,
        metavar="BUILDFILE",
        help=(
            "Path to BuildFile.xml (default: ./BuildFile.xml). "
            "Mutually exclusive with --scan-dir."
        ),
    )
    parser.add_argument(
        "--scan-dir",
        metavar="DIR",
        help=(
            "Convert all BuildFile.xml files found recursively under DIR and "
            "generate structural CMakeLists.txt files. Mutually exclusive with BUILDFILE."
        ),
    )
    parser.add_argument(
        "-o", "--output",
        metavar="FILE",
        help=(
            "Output path (default: CMakeLists.txt next to BUILDFILE). "
            "Use '-' for stdout. Ignored in --scan-dir mode."
        ),
    )
    parser.add_argument(
        "--project",
        metavar="NAME",
        default="",
        help="CMake project name for informational comments (e.g. 'code4hep')",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print to stdout without writing any files",
    )
    parser.add_argument(
        "--map",
        metavar="FILE",
        help=(
            "Path to a .py file with a bare dict literal mapping additional "
            "SCRAM tool names to CMake target strings. Merged over the built-in "
            "SCRAM_TO_CMAKE_TARGETS table; file entries take precedence."
        ),
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Overwrite existing CMakeLists.txt files without prompting",
    )

    args = parser.parse_args()

    if args.scan_dir and args.buildfile:
        parser.error("BUILDFILE and --scan-dir are mutually exclusive.")

    # Build target map (shared by both modes)
    target_map = dict(SCRAM_TO_CMAKE_TARGETS)
    if args.map:
        overrides = load_map_file(args.map)
        target_map.update({k.lower(): v for k, v in overrides.items()})

    # -----------------------------------------------------------------------
    # Scan-dir mode
    # -----------------------------------------------------------------------
    if args.scan_dir:
        scan_root = pathlib.Path(args.scan_dir)
        if not scan_root.is_dir():
            print(
                f"ERROR: --scan-dir '{scan_root}' is not a directory.",
                file=sys.stderr,
            )
            sys.exit(2)

        rc = scan_directory(
            scan_root=scan_root,
            target_map=target_map,
            project_name=args.project,
            dry_run=args.dry_run,
            force=args.force,
        )
        sys.exit(rc)

    # -----------------------------------------------------------------------
    # Single-file mode
    # -----------------------------------------------------------------------
    buildfile_str = args.buildfile if args.buildfile else "BuildFile.xml"
    buildfile_path = pathlib.Path(buildfile_str)
    if not buildfile_path.exists():
        print(
            f"ERROR: BuildFile.xml not found at '{buildfile_path}'.",
            file=sys.stderr,
        )
        sys.exit(2)

    # Resolve output path
    if args.output:
        output_path = None if args.output == "-" else pathlib.Path(args.output)
    else:
        output_path = buildfile_path.parent / "CMakeLists.txt"

    if args.dry_run:
        output_path = None

    if output_path is not None and output_path.exists() and not args.force:
        answer = input(
            f"'{output_path}' already exists. Overwrite? [y/N] "
        ).strip().lower()
        if answer not in ("y", "yes"):
            print("Aborted.", file=sys.stderr)
            sys.exit(0)

    nodes = parse_buildfile(str(buildfile_path))

    ctx = ConvertContext(
        filepath=str(buildfile_path),
        project_name=args.project,
        target_map=target_map,
    )
    statements = convert(nodes, ctx)
    output_text = render(statements, str(buildfile_path))

    if output_path is None:
        print(output_text, end="")
    else:
        output_path.write_text(output_text, encoding="utf-8")
        print(f"Written to '{output_path}'.", file=sys.stderr)

    sys.exit(1 if ctx.errors else 0)


if __name__ == "__main__":
    main()
