from absl.testing import absltest

from document.artboard import Artboard
from document.document import Document
from document.document_setup import DocumentSetup
from document.print_preferences import (
    PrintPreferences, PrintPreset, ArtboardRangeMode, MediaSize, Orientation,
    PrintLayers, ScalingMode, DEFAULT_PRESET,
    MarksAndBleed, PrinterMarkType,
    Output, OutputMode, Emulsion, ImagePolarity, DotShape, InkOverride,
)
from geometry.test_json import document_to_test_json, test_json_to_document


def _make_artboard():
    return Artboard(id="ab", name="A1", x=10.0, y=20.0, width=100.0, height=200.0)


class DocumentSetupTest(absltest.TestCase):
    def test_defaults(self):
        s = DocumentSetup()
        self.assertEqual(s.bleed_top, 0.0)
        self.assertEqual(s.bleed_right, 0.0)
        self.assertEqual(s.bleed_bottom, 0.0)
        self.assertEqual(s.bleed_left, 0.0)
        self.assertTrue(s.bleed_uniform)
        self.assertFalse(s.show_images_outline)
        self.assertFalse(s.highlight_substituted_glyphs)

    def test_bleed_rect_none_when_all_zero(self):
        ab = _make_artboard()
        self.assertIsNone(DocumentSetup().bleed_rect_for_artboard(ab))

    def test_bleed_rect_uniform_extends_all_sides(self):
        ab = _make_artboard()
        s = DocumentSetup(bleed_top=5.0, bleed_right=5.0,
                          bleed_bottom=5.0, bleed_left=5.0)
        self.assertEqual(s.bleed_rect_for_artboard(ab), (5.0, 15.0, 110.0, 210.0))

    def test_bleed_rect_partial_only_offsets_sides_with_bleed(self):
        ab = _make_artboard()
        s = DocumentSetup(bleed_left=7.0)
        self.assertEqual(s.bleed_rect_for_artboard(ab), (3.0, 20.0, 107.0, 200.0))


class PrintPreferencesTest(absltest.TestCase):
    def test_defaults_match_spec(self):
        p = PrintPreferences()
        self.assertEqual(p.preset_name, "[Default]")
        self.assertIsNone(p.printer_name)
        self.assertEqual(p.copies, 1)
        self.assertFalse(p.collate)
        self.assertFalse(p.reverse_order)
        self.assertEqual(p.artboard_range_mode, ArtboardRangeMode.ALL)
        self.assertEqual(p.artboard_range, "")
        self.assertFalse(p.ignore_artboards)
        self.assertFalse(p.skip_blank_artboards)
        self.assertEqual(p.media_size, MediaSize.DEFINED_BY_DRIVER)
        self.assertEqual(p.media_width, 612.0)
        self.assertEqual(p.media_height, 792.0)
        self.assertEqual(p.orientation, Orientation.PORTRAIT)
        self.assertTrue(p.auto_rotate)
        self.assertFalse(p.transverse)
        self.assertEqual(p.print_layers, PrintLayers.VISIBLE_PRINTABLE)
        self.assertEqual(p.placement_x, 0.0)
        self.assertEqual(p.placement_y, 0.0)
        self.assertEqual(p.scaling_mode, ScalingMode.DO_NOT_SCALE)
        self.assertEqual(p.custom_scale, 100.0)
        self.assertEqual(p.tile_overlap_h, 0.0)
        self.assertEqual(p.tile_overlap_v, 0.0)
        self.assertEqual(p.tile_range, "")

    def test_default_preset_holds_defaults(self):
        self.assertEqual(DEFAULT_PRESET.name, "[Default]")
        self.assertEqual(DEFAULT_PRESET.preferences, PrintPreferences())

    def test_enum_strings_snake_case(self):
        self.assertEqual(ArtboardRangeMode.ALL.value, "all")
        self.assertEqual(ArtboardRangeMode.RANGE.value, "range")
        self.assertEqual(MediaSize.DEFINED_BY_DRIVER.value, "defined_by_driver")
        self.assertEqual(MediaSize.TABLOID.value, "tabloid")
        self.assertEqual(Orientation.PORTRAIT.value, "portrait")
        self.assertEqual(PrintLayers.VISIBLE_PRINTABLE.value, "visible_printable")
        self.assertEqual(ScalingMode.DO_NOT_SCALE.value, "do_not_scale")
        self.assertEqual(ScalingMode.FIT_TO_PAGE.value, "fit_to_page")


class TestJsonCodecTest(absltest.TestCase):
    def test_document_setup_omitted_when_default(self):
        j = document_to_test_json(Document())
        self.assertNotIn('"document_setup"', j)

    def test_document_setup_emitted_when_non_default(self):
        d = Document(document_setup=DocumentSetup(bleed_top=9.0))
        j = document_to_test_json(d)
        self.assertIn('"document_setup"', j)
        self.assertIn('"bleed_top":9.0', j)

    def test_document_setup_roundtrip(self):
        s = DocumentSetup(
            bleed_top=9.0, bleed_right=9.0, bleed_bottom=9.0, bleed_left=9.0,
            bleed_uniform=False,
            show_images_outline=True,
            highlight_substituted_glyphs=True,
        )
        d = Document(document_setup=s)
        d2 = test_json_to_document(document_to_test_json(d))
        self.assertEqual(d2.document_setup, s)

    def test_print_preferences_omitted_when_default(self):
        j = document_to_test_json(Document())
        self.assertNotIn('"print_preferences"', j)

    def test_print_preferences_emitted_when_non_default(self):
        d = Document(print_preferences=PrintPreferences(copies=5))
        j = document_to_test_json(d)
        self.assertIn('"print_preferences"', j)
        self.assertIn('"copies":5', j)

    def test_print_preferences_roundtrip(self):
        p = PrintPreferences(
            preset_name="[Default]",
            printer_name="My Laser",
            copies=7, collate=True, reverse_order=True,
            artboard_range_mode=ArtboardRangeMode.RANGE,
            artboard_range="1-3, 5",
            ignore_artboards=True, skip_blank_artboards=True,
            media_size=MediaSize.A4, media_width=595.28, media_height=841.89,
            orientation=Orientation.LANDSCAPE,
            auto_rotate=False, transverse=True,
            print_layers=PrintLayers.ALL,
            placement_x=12.0, placement_y=24.0,
            scaling_mode=ScalingMode.CUSTOM, custom_scale=75.5,
            tile_overlap_h=6.0, tile_overlap_v=6.0, tile_range="1-2",
        )
        d = Document(print_preferences=p)
        d2 = test_json_to_document(document_to_test_json(d))
        self.assertEqual(d2.print_preferences, p)


class MarksAndBleedTest(absltest.TestCase):
    """PRINT.md §Phase 2 sub-record on PrintPreferences."""

    def test_defaults(self):
        m = MarksAndBleed()
        self.assertFalse(m.all_printer_marks)
        self.assertFalse(m.trim_marks)
        self.assertFalse(m.registration_marks)
        self.assertFalse(m.color_bars)
        self.assertFalse(m.page_information)
        self.assertEqual(m.printer_mark_type, PrinterMarkType.ROMAN)
        self.assertEqual(m.trim_mark_weight, 0.25)
        self.assertEqual(m.mark_offset, 6.0)
        self.assertTrue(m.use_document_bleed)
        self.assertEqual(m.bleed_top, 0.0)
        self.assertEqual(m.bleed_right, 0.0)
        self.assertEqual(m.bleed_bottom, 0.0)
        self.assertEqual(m.bleed_left, 0.0)

    def test_printer_mark_type_strings(self):
        self.assertEqual(PrinterMarkType.ROMAN.value, "roman")
        self.assertEqual(PrinterMarkType.JAPANESE.value, "japanese")

    def test_marks_and_bleed_roundtrip(self):
        m = MarksAndBleed(
            all_printer_marks=True, trim_marks=True,
            registration_marks=True, color_bars=True,
            page_information=True,
            printer_mark_type=PrinterMarkType.JAPANESE,
            trim_mark_weight=0.5, mark_offset=12.0,
            use_document_bleed=False,
            bleed_top=4.0, bleed_right=5.0,
            bleed_bottom=6.0, bleed_left=7.0,
        )
        p = PrintPreferences(marks_and_bleed=m)
        d = Document(print_preferences=p)
        j = document_to_test_json(d)
        self.assertIn('"marks_and_bleed"', j)
        d2 = test_json_to_document(j)
        self.assertEqual(d2.print_preferences.marks_and_bleed, m)


class OutputTest(absltest.TestCase):
    """PRINT.md §Phase 3 Output sub-record."""

    def test_defaults(self):
        o = Output()
        self.assertEqual(o.mode, OutputMode.COMPOSITE)
        self.assertEqual(o.emulsion, Emulsion.UP_RIGHT)
        self.assertEqual(o.image_polarity, ImagePolarity.POSITIVE)
        self.assertEqual(o.printer_resolution, "75 lpi / 600 dpi")
        self.assertFalse(o.convert_spot_to_process)
        self.assertFalse(o.overprint_black)
        self.assertEqual(len(o.inks), 4)
        self.assertEqual(o.inks[0].name, "Process Cyan")
        self.assertEqual(o.inks[0].angle, 105.0)
        self.assertEqual(o.inks[1].name, "Process Magenta")
        self.assertEqual(o.inks[2].name, "Process Yellow")
        self.assertEqual(o.inks[3].name, "Process Black")
        self.assertEqual(o.inks[3].angle, 45.0)
        for ink in o.inks:
            self.assertTrue(ink.print)
            self.assertEqual(ink.frequency, 75.0)
            self.assertEqual(ink.dot_shape, DotShape.ROUND)

    def test_enum_strings(self):
        self.assertEqual(OutputMode.COMPOSITE.value, "composite")
        self.assertEqual(OutputMode.SEPARATIONS.value, "separations")
        self.assertEqual(Emulsion.UP_RIGHT.value, "up_right")
        self.assertEqual(Emulsion.DOWN_RIGHT.value, "down_right")
        self.assertEqual(ImagePolarity.POSITIVE.value, "positive")
        self.assertEqual(ImagePolarity.NEGATIVE.value, "negative")
        self.assertEqual(DotShape.ROUND.value, "round")
        self.assertEqual(DotShape.EUCLIDEAN.value, "euclidean")

    def test_output_roundtrip(self):
        o = Output(
            mode=OutputMode.SEPARATIONS,
            emulsion=Emulsion.DOWN_RIGHT,
            image_polarity=ImagePolarity.NEGATIVE,
            printer_resolution="150 lpi / 1200 dpi",
            convert_spot_to_process=True,
            overprint_black=True,
            inks=(
                InkOverride(name="Process Cyan", print=False,
                            frequency=100.0, angle=105.0,
                            dot_shape=DotShape.ELLIPSE),
                InkOverride(name="PANTONE 185 C", print=True,
                            frequency=85.0, angle=45.0,
                            dot_shape=DotShape.SQUARE),
            ),
        )
        p = PrintPreferences(output=o)
        d = Document(print_preferences=p)
        j = document_to_test_json(d)
        self.assertIn('"output"', j)
        self.assertIn('"PANTONE 185 C"', j)
        d2 = test_json_to_document(j)
        self.assertEqual(d2.print_preferences.output, o)


if __name__ == "__main__":
    absltest.main()
