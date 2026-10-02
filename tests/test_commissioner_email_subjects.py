from pathlib import Path
import unittest


SOURCE = Path(__file__).parents[1] / 'R' / 'commissioner_alerts.R'


class CommissionerEmailSubjects(unittest.TestCase):
    def test_private_gm_subjects_include_franchise_name(self):
        text = SOURCE.read_text(encoding='utf-8')
        self.assertIn('franchise_alerts$franchise_name[[1]]', text)
        self.assertIn('franchise_title_prefix, " - ", franchise_label, " - ", date_label', text)


if __name__ == '__main__':
    unittest.main()
