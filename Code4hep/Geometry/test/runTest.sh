#!/bin/bash
# Runs in the build tree. testGeo.xml includes elements.xml and materials.xml
# relative to its own location, so a copy of it is placed here next to links to
# DD4hep's files; CMSSW_SEARCH_PATH (set by the test) makes edm::FileInPath find
# this copy.
set -e
test_dir=$(dirname "$(readlink -f "$0")")
dd4hep_xml_dir=$(dirname "$(readlink -f "$(which ddeve)")")/../DDDetectors/compact
ln -sf "$dd4hep_xml_dir/elements.xml" "$dd4hep_xml_dir/materials.xml" .
cp "$test_dir/testGeo.xml" .
cmsRun "$test_dir/testGeo.py"
