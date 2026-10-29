import sys,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).parents[1]/'scripts'))
from check_automation_contracts import publication_is_manual_only

class PublicationTests(unittest.TestCase):
    def test_validation_push_with_manual_only_publication_cannot_self_publish(self):
        self.assertTrue(publication_is_manual_only("""jobs:
  rebuild:
    steps:
      - name: Validate
        run: python tests.py
      - name: Publish
        if: github.event_name == 'workflow_dispatch'
        run: |
          git push origin HEAD:main
"""))

    def test_one_unguarded_writer_is_not_manual_only(self):
        guarded="""      - name: Publish
        if: github.event_name == 'workflow_dispatch'
        run: |
          git push origin HEAD:main
"""
        self.assertFalse(publication_is_manual_only(guarded+"""      - name: Another writer
        run: |
          git push origin HEAD:main
"""))
        self.assertFalse(publication_is_manual_only(guarded.replace("== 'workflow_dispatch'","!= 'schedule'")))

if __name__=='__main__':unittest.main()
