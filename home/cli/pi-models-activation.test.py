#!/usr/bin/env python3
import copy
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / 'home/services/pi-models-configure.py'
LOCAL = 'llama-cpp/*-local'
CLOUD = 'litellm/gpt-6.2-sol'
QWEN = 'llama-cpp/qwen3.6-35b-a3b-*'
COST = dict(input=0, output=0, cacheRead=0, cacheWrite=0)
LOCAL_PROVIDER = dict(
    baseUrl='http://mac-work.local:8080/v1', api='openai-completions', apiKey='local',
    compat=dict(supportsDeveloperRole=False, supportsReasoningEffort=False, supportsUsageInStreaming=True),
    models=[dict(id='bonsai-2-27b-local', name='Bonsai 2 27B Local (PQ2_0)', input=['text', 'image'],
                 contextWindow=262144, maxTokens=8192, reasoning=False, cost=COST,
                 samplingParams=dict(chat_template_kwargs=dict(enable_thinking=False)))])
CATALOG = json.loads((ROOT / 'home/services/litellm-models.json').read_text())
CLOUD_PROVIDER = dict(baseUrl='@@LITELLM_BASE_URL@@', api='openai-completions',
                      apiKey='!cat /run/secrets/litellm_api_key', compat=dict(supportsDeveloperRole=False),
                      models=[dict(m, cost=COST) for m in CATALOG['models']])


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


KNOWN = {'llama-cpp': [digest(LOCAL_PROVIDER)], 'litellm': [digest(CLOUD_PROVIDER)]}


def desired(local=False, cloud=False):
    return dict(providers={**({'llama-cpp': LOCAL_PROVIDER} if local else {}),
                           **({'litellm': CLOUD_PROVIDER} if cloud else {})},
                defaultModel=CLOUD if cloud else None,
                enabledModels=(['anthropic/claude-opus-4-7'] + (['litellm/*'] if cloud else [])
                               + ([LOCAL] if local else [])) if local or cloud else [],
                modelThinkingLevels={CLOUD: 'high'} if cloud else {})


class Fixture:
    def __init__(self, path):
        self.path = path
        for name in ('models', 'settings', 'receipt', 'desired', 'known'):
            setattr(self, name, path / (name + '.json'))
        self.known.write_text(json.dumps(KNOWN))

    def seed(self, providers=None, settings=None):
        if providers is not None:
            self.models.write_text(json.dumps({'providers': providers}, indent=3))
        if settings is not None:
            self.settings.write_text(json.dumps(settings, indent=3))

    def run(self, config):
        self.desired.write_text(json.dumps(config))
        result = subprocess.run([sys.executable, str(HELPER), '--desired', str(self.desired),
                                 '--models-file', str(self.models), '--settings-file', str(self.settings),
                                 '--receipt-file', str(self.receipt), '--known-legacy', str(self.known)],
                                capture_output=True, text=True)
        if result.returncode:
            raise AssertionError(result.stderr)
        return tuple(json.loads(p.read_text()) if p.exists() else None
                     for p in (self.models, self.settings, self.receipt)) + (result.stderr,)


class Reconciliation(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='t029-models-fixture-')
        self.addCleanup(self.temp.cleanup)
        self.f = Fixture(Path(self.temp.name))

    def test_01_fresh_no_provider(self):
        self.assertEqual(self.f.run(desired()), (None, None, None, ''))
        self.assertEqual(self.f.run(desired()), (None, None, None, ''))

    def test_02_never_managed_same_names_preserved_bytes(self):
        providers = {'litellm': {'baseUrl': 'https://manual.invalid'}, 'llama-cpp': {'apiKey': 'manual'}}
        settings = dict(defaultProvider='litellm', defaultModel='manual', enabledModels=['litellm/*', LOCAL],
                        modelThinkingLevels={CLOUD: 'high'})
        self.f.seed(providers, settings)
        before = [p.read_bytes() for p in (self.f.models, self.f.settings)]
        models, result, receipt, stderr = self.f.run(desired())
        self.assertEqual(models, {'providers': providers})
        self.assertEqual(result, settings)
        self.assertEqual([p.read_bytes() for p in (self.f.models, self.f.settings)], before)
        self.assertEqual(receipt['managedScopes'], [])
        self.assertIn('unestablished legacy provider', stderr)

    def test_03_receipt_backed_cloud_removal(self):
        self.f.seed({'custom': {'api': 'custom'}}, {'enabledModels': ['custom/*'], 'theme': 'user'})
        self.f.run(desired(cloud=True))
        models, settings, receipt, stderr = self.f.run(desired())
        self.assertEqual(models, {'providers': {'custom': {'api': 'custom'}}})
        self.assertEqual(settings, {'enabledModels': ['custom/*'], 'theme': 'user'})
        self.assertEqual(receipt, dict(version=1, providers={}, defaultModel=None, managedScopes=[],
                                       unestablishedScopes=[], unestablishedThinkingKeys=[], modelThinkingLevels={}))
        self.assertEqual(stderr, '')
        self.assertEqual(self.f.run(desired()), (models, settings, receipt, ''))

    def test_04_direct_legacy_removal_and_unknown_default(self):
        self.f.seed({'litellm': CLOUD_PROVIDER, 'llama-cpp': LOCAL_PROVIDER},
                    dict(defaultProvider='llama-cpp', defaultModel='user-model',
                         enabledModels=['anthropic/claude-opus-4-7', 'litellm/*', QWEN]))
        models, settings, receipt, stderr = self.f.run(desired())
        self.assertIsNone(models)
        self.assertEqual(settings, dict(defaultProvider='llama-cpp', defaultModel='user-model',
                                       enabledModels=['anthropic/claude-opus-4-7']))
        self.assertEqual(receipt['managedScopes'], [])
        self.assertEqual(stderr, '')

    def test_05_provider_only_override_protects_settings(self):
        self.f.run(desired(cloud=True))
        models = json.loads(self.f.models.read_text())
        models['providers']['litellm']['models'][0]['maxTokens'] = 4096
        self.f.models.write_text(json.dumps(models))
        before = self.f.settings.read_bytes()
        actual, settings, receipt, stderr = self.f.run(desired())
        self.assertEqual(actual, models)
        self.assertEqual(self.f.settings.read_bytes(), before)
        self.assertEqual(settings['modelThinkingLevels'], {CLOUD: 'high'})
        self.assertEqual(receipt['providers'], {})
        self.assertIn('user-modified provider', stderr)

    def test_06_namespace_isolation(self):
        self.f.run(desired(local=True, cloud=True))
        models = json.loads(self.f.models.read_text())
        models['providers']['litellm']['compat']['supportsDeveloperRole'] = True
        self.f.models.write_text(json.dumps(models))
        actual, settings, receipt, stderr = self.f.run(desired())
        self.assertEqual(actual, {'providers': {'litellm': models['providers']['litellm']}})
        self.assertNotIn(LOCAL, settings['enabledModels'])
        self.assertIn('litellm/*', settings['enabledModels'])
        self.assertEqual(settings['defaultProvider'], 'litellm')
        self.assertEqual(settings['modelThinkingLevels'], {CLOUD: 'high'})
        self.assertEqual(receipt['managedScopes'], [])
        self.assertIn('litellm', stderr)

    def test_07_legacy_field_and_private_url_overrides(self):
        for field, value in [('maxTokens', 4096), ('contextWindow', 24000),
                             ('compat', {'supportsDeveloperRole': True}), ('samplingParams', {'temperature': 0.1}),
                             ('baseUrl', 'https://manual.invalid')]:
            with self.subTest(field=field), tempfile.TemporaryDirectory(prefix='t029-models-fixture-') as tmp:
                f = Fixture(Path(tmp))
                provider = copy.deepcopy(CLOUD_PROVIDER)
                if field in ('maxTokens', 'contextWindow', 'samplingParams'):
                    provider['models'][0][field] = value
                else:
                    provider[field] = value
                settings = dict(defaultProvider='litellm', defaultModel='gpt-6.2-sol', enabledModels=['litellm/*'])
                f.seed({'litellm': provider}, settings)
                models, actual, receipt, stderr = f.run(desired())
                self.assertEqual(models, {'providers': {'litellm': provider}})
                self.assertEqual(actual, settings)
                self.assertEqual(receipt['managedScopes'], [])
                self.assertIn('unestablished legacy provider', stderr)
                self.assertNotIn('manual.invalid', stderr)

    def test_08_field_overrides_objects_and_qwen_ordering(self):
        rich = dict(model=QWEN, thinkingLevel='low')
        self.f.seed({'llama-cpp': LOCAL_PROVIDER}, {'enabledModels': [rich, 'custom/*'],
                                                 'modelThinkingLevels': {CLOUD: 'medium'}})
        self.f.run(desired(local=True, cloud=True))
        settings = json.loads(self.f.settings.read_text())
        self.assertEqual(settings['enabledModels'][0], dict(model=LOCAL, thinkingLevel='low'))
        self.assertEqual(settings['modelThinkingLevels'][CLOUD], 'medium')
        settings['defaultProvider'], settings['defaultModel'] = 'custom', 'own'
        self.f.settings.write_text(json.dumps(settings))
        models, actual, receipt, stderr = self.f.run(desired())
        self.assertIsNone(models)
        self.assertEqual(actual, dict(enabledModels=[dict(model=LOCAL, thinkingLevel='low'), 'custom/*'],
                                      defaultProvider='custom', defaultModel='own', modelThinkingLevels={CLOUD: 'medium'}))
        self.assertEqual(receipt['unestablishedThinkingKeys'], [CLOUD])
        self.assertEqual(stderr, '')

    def test_09_exact_legacy_active_twice_local_removed(self):
        for enabled in ([ 'anthropic/claude-opus-4-7', 'litellm/*', LOCAL ],
                        [ 'anthropic/claude-opus-4-7', LOCAL, 'litellm/*' ],
                        [ 'anthropic/claude-opus-4-7', 'litellm/*', QWEN ]):
            with self.subTest(enabled=enabled), tempfile.TemporaryDirectory(prefix='t029-models-fixture-') as tmp:
                f = Fixture(Path(tmp)); f.seed({'llama-cpp': LOCAL_PROVIDER}, {'enabledModels': enabled})
                for _ in range(2):
                    models, settings, receipt, stderr = f.run(desired(local=True, cloud=True))
                    self.assertEqual(models, {'providers': desired(local=True, cloud=True)['providers']})
                    self.assertIn(LOCAL, settings['enabledModels'])
                    self.assertIn(LOCAL, receipt['managedScopes'])
                    self.assertEqual(receipt['unestablishedScopes'], [])
                    self.assertEqual(stderr, '')
                models, settings, receipt, stderr = f.run(desired(cloud=True))
                self.assertEqual(models, {'providers': {'litellm': CLOUD_PROVIDER}})
                self.assertEqual(settings['enabledModels'], ['anthropic/claude-opus-4-7', 'litellm/*'])
                self.assertNotIn(LOCAL, receipt['managedScopes'])
                self.assertEqual(stderr, '')

    def test_10_normalization_never_grants_ownership(self):
        modified = copy.deepcopy(LOCAL_PROVIDER); modified['models'][0]['maxTokens'] = 4096
        for providers, enabled in [({'llama-cpp': modified}, [QWEN]), ({}, [QWEN]),
                                    ({'llama-cpp': LOCAL_PROVIDER}, ['custom/foo', LOCAL])]:
            with self.subTest(providers=bool(providers)), tempfile.TemporaryDirectory(prefix='t029-models-fixture-') as tmp:
                f = Fixture(Path(tmp)); f.seed(providers, {'enabledModels': enabled})
                for _ in range(2):
                    models, settings, receipt, stderr = f.run(desired(local=True))
                    self.assertEqual(models, {'providers': {'llama-cpp': LOCAL_PROVIDER}})
                    self.assertIn(LOCAL, settings['enabledModels'])
                    self.assertEqual(receipt['managedScopes'], [])
                    self.assertEqual(receipt['unestablishedScopes'], [LOCAL])
                models, settings, receipt, stderr = f.run(desired())
                self.assertIsNone(models)
                self.assertIn(LOCAL, settings['enabledModels'])
                self.assertEqual(receipt['managedScopes'], [])
                self.assertEqual(receipt['unestablishedScopes'], [LOCAL])
                self.assertIn('preserving unestablished scope', stderr)
                self.assertEqual(f.receipt.stat().st_mode & 0o777, 0o600)


if __name__ == '__main__':
    unittest.main()
