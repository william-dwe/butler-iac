import importlib.util
import pathlib
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).with_name("dotenv-env.py")
spec = importlib.util.spec_from_file_location("dotenv_env", SCRIPT)
dotenv_env = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dotenv_env)


class DotenvEnvTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.tmp.name)
        self.source = self.root / "decrypted"
        self.output = self.root / "rendered"

    def tearDown(self):
        self.tmp.cleanup()

    def rewrite(self, content):
        self.source.write_bytes(content)
        dotenv_env.rewrite(self.source, self.output, "100.64.0.1", "https://butler.example.com")
        return self.output.read_bytes()

    def test_valid_export_and_host_values(self):
        output = self.rewrite(
            b"#/---[DOTENV_PUBLIC_KEY]---/\n"
            b"DOTENV_PUBLIC_KEY=\"02abc\"\n"
            b"\n"
            b"# imported\n\nSECRET=not-disclosed\nTAILSCALE_IP=old\nBUTLER_ORIGIN=old\nBUTLER_WEB_ORIGIN=old\n"
        )
        self.assertEqual(
            output,
            b"\n# imported\n\nSECRET=not-disclosed\nTAILSCALE_IP=100.64.0.1\n"
            b"BUTLER_ORIGIN=https://butler.example.com\nBUTLER_WEB_ORIGIN=https://butler.example.com\n",
        )

    def test_rejects_invalid_or_duplicate_assignments(self):
        for content in (b"export NAME=value\n", b"NAME=one\nNAME=two\n", b"NAME=ok\x00\n"):
            with self.subTest(content=content.split(b"=", 1)[0]):
                self.source.write_bytes(content)
                with self.assertRaises(ValueError):
                    dotenv_env.rewrite(self.source, self.output, "100.64.0.1", "https://butler.example.com")


if __name__ == "__main__":
    unittest.main()
