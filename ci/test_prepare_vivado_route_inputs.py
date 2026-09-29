from __future__ import annotations

import hashlib
from pathlib import Path
import tempfile
import unittest

from ci.prepare_vivado_route_inputs import check_project_references


class VivadoInputPreparationTests(unittest.TestCase):
    def make_fixture(self, root: Path, local_data: bytes = b"legacy-top\n") -> tuple[Path, Path, dict[str, tuple[str, str, str]]]:
        project = root / "work" / "probe"
        sources = project / "frs_clg400_probe.srcs" / "sources_1" / "imports" / "AD936X_PL" / "projects" / "fmcomms2" / "zc702"
        legacy = root / "legacy"
        sources.mkdir(parents=True)
        legacy_file = legacy / "projects/fmcomms2/zc702/legacy_system_top.v"
        legacy_file.parent.mkdir(parents=True)
        legacy_file.write_bytes(local_data)
        (sources / "system_top.v").write_bytes(local_data)
        xpr = project / "frs_clg400_probe.xpr"
        xpr.write_text(
            '''<Project><Option Name="Part" Val="xc7z020clg400-2"/>
            <File Path="$PSRCDIR/sources_1/imports/AD936X_PL/projects/fmcomms2/zc702/system_top.v">
              <FileInfo><Attr Name="ImportPath" Val="$PPRDIR/../vendor/MyCore_7010_V3/AD936X_PL/projects/fmcomms2/zc702/system_top.v"/></FileInfo>
            </File></Project>''',
            encoding="utf-8",
        )
        imported = "projects/fmcomms2/zc702/system_top.v"
        mapping = {
            imported: (
                "sources_1/imports/AD936X_PL/projects/fmcomms2/zc702/system_top.v",
                "projects/fmcomms2/zc702/legacy_system_top.v",
                hashlib.sha256(local_data).hexdigest(),
            )
        }
        return xpr, legacy, mapping

    def test_accepts_stale_provenance_when_pinned_psrc_copy_exists(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            xpr, legacy, mapping = self.make_fixture(Path(temp))
            manifest = check_project_references(xpr, legacy, mapping)
        self.assertEqual(manifest, [("projects/fmcomms2/zc702/system_top.v", mapping["projects/fmcomms2/zc702/system_top.v"][2])])

    def test_rejects_modified_project_copy(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            xpr, legacy, mapping = self.make_fixture(Path(temp))
            local = xpr.parent / f"{xpr.stem}.srcs" / mapping[next(iter(mapping))][0]
            local.write_text("tampered\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "differs from pinned legacy archive"):
                check_project_references(xpr, legacy, mapping)

    def test_rejects_missing_psrc_copy_even_if_provenance_is_unresolved(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            xpr, legacy, mapping = self.make_fixture(Path(temp))
            local = xpr.parent / f"{xpr.stem}.srcs" / mapping[next(iter(mapping))][0]
            local.unlink()
            with self.assertRaisesRegex(ValueError, "local PSRCDIR copy is missing"):
                check_project_references(xpr, legacy, mapping)


if __name__ == "__main__":
    unittest.main()
