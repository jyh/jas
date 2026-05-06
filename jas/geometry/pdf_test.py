from absl.testing import absltest

from document.artboard import Artboard
from document.document import Document
from document.print_preferences import (
    PrintPreferences, PrintLayers, Output, OutputMode, InkOverride,
)
from geometry.pdf import document_to_pdf


class PdfEnvelopeTest(absltest.TestCase):
    def test_default_doc_is_valid_pdf(self):
        b = document_to_pdf(Document())
        self.assertTrue(b.startswith(b"%PDF-"))
        self.assertIn(b"%%EOF", b)

    def test_one_artboard_yields_one_page(self):
        ab = Artboard(id="a", name="A1", x=0, y=0, width=100, height=100)
        b = document_to_pdf(Document(artboards=(ab,)))
        # ReportLab's PDFs include "/Count N" in the pages tree.
        self.assertIn(b"/Count 1", b)

    def test_n_artboards_yields_n_pages(self):
        abs_ = (
            Artboard(id="a", x=0, y=0, width=100, height=100),
            Artboard(id="b", x=0, y=200, width=200, height=200),
            Artboard(id="c", x=0, y=500, width=50, height=50),
        )
        b = document_to_pdf(Document(artboards=abs_))
        self.assertIn(b"/Count 3", b)

    def test_ignore_artboards_collapses_to_one_page(self):
        abs_ = (
            Artboard(id="a", x=0, y=0, width=100, height=100),
            Artboard(id="b", x=200, y=200, width=200, height=200),
        )
        d = Document(artboards=abs_,
                     print_preferences=PrintPreferences(ignore_artboards=True))
        b = document_to_pdf(d)
        self.assertIn(b"/Count 1", b)

    def test_print_layers_filter_runs_without_error(self):
        # Smoke: emit with each filter setting; non-default produces
        # a different doc but still valid bytes.
        for f in (PrintLayers.VISIBLE_PRINTABLE, PrintLayers.VISIBLE, PrintLayers.ALL):
            d = Document(print_preferences=PrintPreferences(print_layers=f))
            b = document_to_pdf(d)
            self.assertTrue(b.startswith(b"%PDF-"))


class PdfSeparationsTest(absltest.TestCase):
    """PRINT.md §Phase 3 separations pagination."""

    def _make_artboard_doc(self, output: Output) -> Document:
        ab = Artboard(id="a", name="A1", x=0, y=0, width=100, height=100)
        return Document(
            artboards=(ab,),
            print_preferences=PrintPreferences(output=output),
        )

    def test_separations_produces_more_bytes_than_composite(self):
        composite = self._make_artboard_doc(Output(mode=OutputMode.COMPOSITE))
        sep = self._make_artboard_doc(Output(mode=OutputMode.SEPARATIONS))
        self.assertGreater(len(document_to_pdf(sep)),
                           2 * len(document_to_pdf(composite)))

    def test_separations_skips_unprinted_inks(self):
        # Disable Cyan + Magenta — should leave 2 pages.
        full_inks = Output().inks
        cyan = full_inks[0]
        magenta = full_inks[1]
        custom_inks = (
            InkOverride(name=cyan.name, print=False, frequency=cyan.frequency,
                        angle=cyan.angle, dot_shape=cyan.dot_shape),
            InkOverride(name=magenta.name, print=False, frequency=magenta.frequency,
                        angle=magenta.angle, dot_shape=magenta.dot_shape),
            full_inks[2], full_inks[3],
        )
        two_inks = self._make_artboard_doc(
            Output(mode=OutputMode.SEPARATIONS, inks=custom_inks))
        four_inks = self._make_artboard_doc(Output(mode=OutputMode.SEPARATIONS))
        self.assertLess(len(document_to_pdf(two_inks)),
                        len(document_to_pdf(four_inks)))

    def test_separations_zero_inks_falls_back_to_composite(self):
        zero_inks = tuple(
            InkOverride(name=i.name, print=False, frequency=i.frequency,
                        angle=i.angle, dot_shape=i.dot_shape)
            for i in Output().inks
        )
        zero = self._make_artboard_doc(
            Output(mode=OutputMode.SEPARATIONS, inks=zero_inks))
        composite = self._make_artboard_doc(Output(mode=OutputMode.COMPOSITE))
        # Empty ink list → falls through to a single composite page.
        # Outputs should be roughly the same size.
        self.assertLess(abs(len(document_to_pdf(zero)) -
                            len(document_to_pdf(composite))), 200)


if __name__ == "__main__":
    absltest.main()
