# Code4hep: Collider Optimization Development Environment for High Energy Physics

## Testing

To run unit tests from this directory, after compiling with CMake:
```
ctest --test-dir build_Code4hep
```


## Development with Spack

The `c4h-full` container image (`ghcr.io/code4hep/c4h-full`) contains Code4hep
and all its dependencies installed with Spack, plus two helper commands from
[c4h-dist](https://github.com/code4hep/c4h-dist):

```
c4hinit <area> [--source <path> | --ref <git-ref>] [--repo <url>] [-j N]
cd <area>
c4henv
ctest --test-dir build
```

`c4hinit` creates a development area in which only Code4hep is rebuilt (with
`spack develop`) on top of the installed release; `c4henv` sets up the run-time
environment for it. After editing the sources, rebuild with
`spack -e <area> install`. See the c4h-dist README for details.

## Continuous integration

`.github/workflows/ci.yaml` runs on every push and pull request in the
`c4h-full` container:

- `build-test` builds Code4hep from the checked-out sources with `c4hinit` and
  runs `ctest`.
- `static-analysis` runs `clang-tidy` (using the exported
  `compile_commands.json`) and `clang-format --dry-run`. Both are report-only
  until the project adds `.clang-tidy` and `.clang-format` files.
