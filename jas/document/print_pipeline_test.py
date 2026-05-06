from absl.testing import absltest

from document.artboard import Artboard
from document.document import Document
from document.document_setup import DocumentSetup
from document.print_preferences import (
    PrintPreferences, PrintPreset, ArtboardRangeMode, MediaSize, Orientation,
    PrintLayers, ScalingMode, DEFAULT_PRESET,
    MarksAndBleed, PrinterMarkType,
    Output, OutputMode, Emulsion, ImagePolarity, DotShape, InkOverride,
    Graphics, FontDownload, PostScriptLevel, DataFormat,
    ColorManagement, ColorHandling, RenderingIntent,
    Advanced, FlattenerPreset,
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


class GraphicsTest(absltest.TestCase):
    """PRINT.md §Phase 4 Graphics sub-record."""

    def test_defaults(self):
        g = Graphics()
        self.assertEqual(g.flatness, 1.0)
        self.assertEqual(g.font_download, FontDownload.SUBSET)
        self.assertEqual(g.postscript_level, PostScriptLevel.LEVEL_3)
        self.assertEqual(g.data_format, DataFormat.BINARY)
        self.assertFalse(g.compatible_gradient_printing)
        self.assertEqual(g.raster_effects_resolution, 300.0)

    def test_enum_strings(self):
        self.assertEqual(FontDownload.NONE.value, "none")
        self.assertEqual(FontDownload.SUBSET.value, "subset")
        self.assertEqual(FontDownload.COMPLETE.value, "complete")
        self.assertEqual(PostScriptLevel.LEVEL_2.value, "level_2")
        self.assertEqual(PostScriptLevel.LEVEL_3.value, "level_3")
        self.assertEqual(DataFormat.ASCII.value, "ascii")
        self.assertEqual(DataFormat.BINARY.value, "binary")

    def test_graphics_roundtrip(self):
        g = Graphics(
            flatness=0.4,
            font_download=FontDownload.COMPLETE,
            postscript_level=PostScriptLevel.LEVEL_2,
            data_format=DataFormat.ASCII,
            compatible_gradient_printing=True,
            raster_effects_resolution=600.0,
        )
        p = PrintPreferences(graphics=g)
        d = Document(print_preferences=p)
        j = document_to_test_json(d)
        self.assertIn('"graphics"', j)
        self.assertIn('"flatness":0.4', j)
        d2 = test_json_to_document(j)
        self.assertEqual(d2.print_preferences.graphics, g)


class ColorManagementTest(absltest.TestCase):
    """PRINT.md §Phase 5 ColorManagement sub-record."""

    def test_defaults(self):
        c = ColorManagement()
        self.assertEqual(c.document_profile, "sRGB IEC61966-2.1")
        self.assertEqual(c.color_handling, ColorHandling.LET_APP_DETERMINE)
        self.assertEqual(c.printer_profile, "")
        self.assertEqual(c.rendering_intent, RenderingIntent.RELATIVE_COLORIMETRIC)
        self.assertFalse(c.preserve_rgb_numbers)

    def test_enum_strings(self):
        self.assertEqual(ColorHandling.LET_APP_DETERMINE.value, "let_app_determine")
        self.assertEqual(ColorHandling.LET_PRINTER_DETERMINE.value, "let_printer_determine")
        self.assertEqual(ColorHandling.POSTSCRIPT_COLOR_MANAGEMENT.value, "postscript_color_management")
        self.assertEqual(RenderingIntent.PERCEPTUAL.value, "perceptual")
        self.assertEqual(RenderingIntent.RELATIVE_COLORIMETRIC.value, "relative_colorimetric")
        self.assertEqual(RenderingIntent.SATURATION.value, "saturation")
        self.assertEqual(RenderingIntent.ABSOLUTE_COLORIMETRIC.value, "absolute_colorimetric")

    def test_color_management_roundtrip(self):
        c = ColorManagement(
            document_profile="Adobe RGB (1998)",
            color_handling=ColorHandling.POSTSCRIPT_COLOR_MANAGEMENT,
            printer_profile="U.S. Web Coated (SWOP) v2",
            rendering_intent=RenderingIntent.SATURATION,
            preserve_rgb_numbers=True,
        )
        p = PrintPreferences(color_management=c)
        d = Document(print_preferences=p)
        j = document_to_test_json(d)
        self.assertIn('"color_management"', j)
        self.assertIn('"color_handling":"postscript_color_management"', j)
        d2 = test_json_to_document(j)
        self.assertEqual(d2.print_preferences.color_management, c)


class AdvancedTest(absltest.TestCase):
    """PRINT.md §Phase 6 Advanced sub-record."""

    def test_defaults(self):
        a = Advanced()
        self.assertFalse(a.print_as_bitmap)
        self.assertEqual(a.overprint_flattener_preset,
                         FlattenerPreset.MEDIUM_RESOLUTION)

    def test_flattener_preset_strings(self):
        self.assertEqual(FlattenerPreset.LOW_RESOLUTION.value, "low_resolution")
        self.assertEqual(FlattenerPreset.MEDIUM_RESOLUTION.value, "medium_resolution")
        self.assertEqual(FlattenerPreset.HIGH_RESOLUTION.value, "high_resolution")
        self.assertEqual(FlattenerPreset.CUSTOM.value, "custom")

    def test_advanced_roundtrip(self):
        a = Advanced(
            print_as_bitmap=True,
            overprint_flattener_preset=FlattenerPreset.HIGH_RESOLUTION,
        )
        p = PrintPreferences(advanced=a)
        d = Document(print_preferences=p)
        j = document_to_test_json(d)
        self.assertIn('"advanced"', j)
        self.assertIn('"print_as_bitmap":true', j)
        d2 = test_json_to_document(j)
        self.assertEqual(d2.print_preferences.advanced, a)

    def test_document_setup_phase6_roundtrip(self):
        s = DocumentSetup(
            grid_size=36.0,
            grid_color="#0099ff",
            paper_color="#fff8e7",
            simulate_colored_paper=True,
            transparency_flattener_preset=FlattenerPreset.HIGH_RESOLUTION,
            discard_white_overprint=True,
        )
        d = Document(document_setup=s)
        j = document_to_test_json(d)
        self.assertIn('"grid_size":36.0', j)
        self.assertIn('"paper_color":"#fff8e7"', j)
        self.assertIn('"simulate_colored_paper":true', j)
        d2 = test_json_to_document(j)
        self.assertEqual(d2.document_setup, s)


if __name__ == "__main__":
    absltest.main()
