import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


def strip_ps(s):
    out = []
    i = 0
    n = len(s)
    state = "code"
    while i < n:
        c = s[i]
        if state == "code":
            if s.startswith("@'", i):
                state = "here_s"; out.extend("  "); i += 2; continue
            if s.startswith('@"', i):
                state = "here_d"; out.extend("  "); i += 2; continue
            if c == '#':
                state = "comment"; out.append(' '); i += 1; continue
            if c == "'":
                state = "single"; out.append(' '); i += 1; continue
            if c == '"':
                state = "double"; out.append(' '); i += 1; continue
            out.append(c); i += 1; continue
        if state == "comment":
            if c == '\n':
                state = "code"; out.append('\n')
            else:
                out.append(' ')
            i += 1; continue
        if state == "single":
            if c == "'":
                if i + 1 < n and s[i + 1] == "'":
                    out.extend("  "); i += 2; continue
                state = "code"
            out.append('\n' if c == '\n' else ' '); i += 1; continue
        if state == "double":
            if c == '`' and i + 1 < n:
                out.extend("  "); i += 2; continue
            if c == '"':
                state = "code"
            out.append('\n' if c == '\n' else ' '); i += 1; continue
        if state == "here_s":
            if (i == 0 or s[i - 1] == '\n') and s.startswith("'@", i):
                state = "code"; out.extend("  "); i += 2; continue
            out.append('\n' if c == '\n' else ' '); i += 1; continue
        if state == "here_d":
            if (i == 0 or s[i - 1] == '\n') and s.startswith('"@', i):
                state = "code"; out.extend("  "); i += 2; continue
            out.append('\n' if c == '\n' else ' '); i += 1; continue
    return ''.join(out), state


class PowerShellStructure(unittest.TestCase):
    def test_balanced_delimiters(self):
        for p in ROOT.rglob('*.ps1'):
            with self.subTest(path=str(p.relative_to(ROOT))):
                t, state = strip_ps(p.read_text(encoding='utf-8-sig'))
                stack = []
                pairs = {')': '(', ']': '[', '}': '{'}
                for c in t:
                    if c in '([{':
                        stack.append(c)
                    elif c in ')]}':
                        self.assertTrue(stack, f'unexpected {c}')
                        self.assertEqual(stack.pop(), pairs[c])
                self.assertEqual(state, 'code')
                self.assertFalse(stack)


if __name__ == '__main__':
    unittest.main()
