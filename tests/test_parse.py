import unittest

from src.omarchy_toggl.parse import ParseError, parse

PROJECTS = [
    {"id": 1, "name": "Snowball"}, {"id": 2, "name": "Generic"}, {"id": 3, "name": "stonks"},
    {"id": 4, "name": "Client Work"}, {"id": 5, "name": "Client Admin"}, {"id": 6, "name": "Old", "active": False},
]


class ParseTests(unittest.TestCase):
    def test_full_grammar(self):
        q = parse("Research @stonks #deep #review $", PROJECTS)
        self.assertEqual(q.description, "Research")
        self.assertEqual(q.project_id, 3)
        self.assertEqual(q.tags, ["deep", "review"])
        self.assertTrue(q.billable)

    def test_quoted_project_and_prefix(self):
        self.assertEqual(parse('Call @"Client Work"', PROJECTS).project_id, 4)
        self.assertEqual(parse("x @snow", PROJECTS).project_id, 1)
        self.assertEqual(parse("x @GENERIC", PROJECTS).project_id, 2)

    def test_ambiguous_project_lists_candidates(self):
        with self.assertRaises(ParseError) as ctx:
            parse("x @client", PROJECTS)
        self.assertIn("Client Work", ctx.exception.candidates)

    def test_unknown_project(self):
        with self.assertRaises(ParseError):
            parse("x @nope", PROJECTS)

    def test_none_project(self):
        q = parse("x @none", PROJECTS)
        self.assertTrue(q.project_set)
        self.assertIsNone(q.project_id)

    def test_plain_description(self):
        q = parse("  write the report  ", PROJECTS)
        self.assertEqual(q.description, "write the report")
        self.assertFalse(q.project_set)
        self.assertIsNone(q.billable)


if __name__ == "__main__":
    unittest.main()
