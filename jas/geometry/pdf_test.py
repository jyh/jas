from absl.testing import absltest

from document.artboard import Artboard
from document.document import Document
from document.print_preferences import PrintPreferences, PrintLayers
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


if __name__ == "__main__":
    absltest.main()
