import base64
from datetime import datetime, timedelta, timezone
import hashlib
import io
import json
from pathlib import Path
import runpy
import tempfile
import unittest

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

PUBLISH = runpy.run_path(str(Path(__file__).resolve().parents[1] / 'release/publish_r2.py'))
FEED = PUBLISH['FEED']


class Missing(Exception):
    response = {'Error': {'Code': 'NoSuchKey'}}


class R2:
    def __init__(self):
        self.objects = {}
        self.writes = []
        self.fail_image = False
        self.corrupt_read = False

    def get_object(self, Bucket, Key):
        if Key not in self.objects:
            raise Missing()
        data = self.objects[Key]
        if self.corrupt_read and Key.endswith('.dmg'):
            data = b'corrupt upload'
        return {'Body': io.BytesIO(data), 'ETag': hashlib.sha256(data).hexdigest()}

    def put_object(self, **args):
        key = args['Key']
        if key.endswith('.dmg') and self.fail_image:
            raise RuntimeError('upload failed')
        if args.get('IfNoneMatch') == '*' and key in self.objects:
            raise RuntimeError('precondition failed')
        if 'IfMatch' in args and hashlib.sha256(self.objects[key]).hexdigest() != args['IfMatch']:
            raise RuntimeError('precondition failed')
        body = args['Body']
        self.objects[key] = body.read() if hasattr(body, 'read') else body
        self.writes.append((key, args))

    def copy_object(self, **args):
        self.objects[args['Key']] = self.objects[args['CopySource']['Key']]
        self.writes.append((args['Key'], args))


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.key = Ed25519PrivateKey.generate()
        self.public = self.key.public_key().public_bytes_raw()
        self.r2 = R2()
        self.fixture()

    def fixture(self, build='200', image=b'image fixture', expired=False, url=None):
        payload = json.dumps({'build': build, 'version': '0.1.0', 'minimumMacOS': 15,
            'bytes': len(image), 'sha256': hashlib.sha256(image).hexdigest(),
            'url': url or f'https://assets.bowser.app/releases/{build}/Bowser.dmg',
            'expiresAt': (datetime.now(timezone.utc) + timedelta(days=-1 if expired else 30)).isoformat()}).encode()
        envelope = json.dumps({'payload': base64.b64encode(payload).decode(),
                              'signature': base64.b64encode(self.key.sign(payload)).decode()}).encode()
        (self.root / 'stable.json').write_bytes(envelope)
        (self.root / 'Bowser.dmg').write_bytes(image)
        return envelope

    def publish(self):
        PUBLISH['publish'](self.r2, 'bowser', self.root, self.public)

    def test_image_verified_before_stable_promotion_and_cache_headers(self):
        self.publish()
        names = [name for name, _ in self.r2.writes]
        self.assertEqual(names, ['releases/200/Bowser.dmg', 'releases/200/stable.json', 'Bowser.dmg', FEED])
        self.assertEqual(self.r2.objects['Bowser.dmg'], b'image fixture')
        self.assertIn('immutable', self.r2.writes[0][1]['CacheControl'])
        self.assertEqual(self.r2.writes[-1][1]['CacheControl'], 'no-store')
        self.assertEqual(self.r2.writes[-1][1]['IfNoneMatch'], '*')

    def test_corrupt_local_image_never_uploads(self):
        (self.root / 'Bowser.dmg').write_bytes(b'corrupt')
        with self.assertRaises(ValueError): self.publish()
        self.assertEqual(self.r2.writes, [])

    def test_invalid_signature_never_uploads(self):
        self.public = Ed25519PrivateKey.generate().public_key().public_bytes_raw()
        with self.assertRaises(Exception): self.publish()
        self.assertEqual(self.r2.writes, [])

    def test_expiry_and_wrong_origin_rejected(self):
        for kwargs in [dict(expired=True), dict(url='https://api.bowser.app/updates/Bowser.dmg')]:
            self.fixture(**kwargs)
            with self.assertRaises(ValueError): self.publish()
        self.assertEqual(self.r2.writes, [])

    def test_upload_failure_preserves_feed(self):
        old = self.fixture(build='100')
        self.r2.objects[FEED] = old
        self.fixture()
        self.r2.fail_image = True
        with self.assertRaises(RuntimeError): self.publish()
        self.assertEqual(self.r2.objects[FEED], old)

    def test_older_release_cannot_replace_newer(self):
        self.r2.objects[FEED] = self.fixture(build='300')
        self.fixture()
        with self.assertRaises(ValueError): self.publish()
        self.assertEqual(self.r2.writes, [])

    def test_existing_build_cannot_be_overwritten(self):
        self.r2.objects['releases/200/Bowser.dmg'] = b'different bytes'
        with self.assertRaises(ValueError): self.publish()
        self.assertEqual(self.r2.writes, [])

    def test_retry_reuses_immutable_image_and_conditionally_promotes(self):
        self.publish()
        self.r2.writes.clear()
        self.publish()
        self.assertNotIn('releases/200/Bowser.dmg', [name for name, _ in self.r2.writes])
        self.assertIn('IfMatch', self.r2.writes[-1][1])


    def test_corrupt_uploaded_image_cannot_promote_feed(self):
        self.r2.corrupt_read = True
        with self.assertRaises(ValueError): self.publish()
        self.assertNotIn(FEED, self.r2.objects)
        self.assertNotIn('Bowser.dmg', self.r2.objects)
