#!/usr/bin/env python3
"""Reference tokenizer counts for archived instruction payloads (not API billing)."""

import argparse
import json

import tiktoken

import run


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('tag', nargs='?', default='three-way')
    opts = parser.parse_args()
    out = run.HERE / opts.tag
    encoders = {name: tiktoken.get_encoding(name) for name in ('o200k_base', 'cl100k_base')}
    payloads = {'native_compression_instructions': '',
                'pi_inline_AGENTS': (out / 'pi-guidance.md').read_text(),
                'rtk_initial_AGENTS_reference': (out / 'rtk-installed/AGENTS.md').read_text(),
                'rtk_installed_RTK_document': (out / 'rtk-installed/RTK.md').read_text(),
                'rtk_default_awareness_without_header': (out / 'rtk-default-awareness.md').read_text()}
    result = {'tiktoken_version': tiktoken.__version__,
              'scope': 'Exact counts under these two reference encodings for standalone payloads; not a claim about the private model tokenizer or provider billing. Excludes Codex message framing and repeated-context effects.',
              'payloads': {name: {'bytes': len(text.encode()), **{enc: len(e.encode(text)) for enc, e in encoders.items()}}
                           for name, text in payloads.items()}}
    run.save_json(out / 'instruction-sizes.json', result)
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
