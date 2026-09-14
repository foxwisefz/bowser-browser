#!/usr/bin/env python3
"""Verify and publish a desktop release to the assets.bowser.app R2 bucket."""
import base64
from contextlib import closing
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

ORIGIN = 'https://assets.bowser.app'
FEED = 'updates/stable.json'
IMMUTABLE = 'public, max-age=31536000, immutable'
MUTABLE = 'no-store'


def manifest(data, public_key, require_fresh=True):
    if len(data) > 16384:
        raise ValueError('Manifest exceeds size limit')
    envelope = json.loads(data)
    payload = base64.b64decode(envelope['payload'], validate=True)
    signature = base64.b64decode(envelope['signature'], validate=True)
    Ed25519PublicKey.from_public_bytes(public_key).verify(signature, payload)
    value = json.loads(payload)
    build = value['build']
    if not isinstance(build, str) or not re.fullmatch(r'[0-9]{1,20}', build) or int(build) >= 2**64:
        raise ValueError('Invalid build')
    if value['url'] != f'{ORIGIN}/releases/{build}/Bowser.dmg':
        raise ValueError('Manifest must name the build-specific assets URL')
    if not isinstance(value['bytes'], int) or not 0 < value['bytes'] <= 1073741824:
        raise ValueError('Invalid image size')
    if not re.fullmatch('[a-f0-9]{64}', value['sha256']):
        raise ValueError('Invalid image hash')
    expiry = datetime.fromisoformat(value['expiresAt'].replace('Z', '+00:00'))
    if require_fresh and expiry <= datetime.now(timezone.utc):
        raise ValueError('Manifest expired; sign a fresh manifest')
    return value


def get(client, bucket, key):
    try:
        return client.get_object(Bucket=bucket, Key=key)
    except Exception as error:
        if getattr(error, 'response', {}).get('Error', {}).get('Code') in ('NoSuchKey', '404'):
            return None
        raise


def digest(stream):
    size, hash_ = 0, hashlib.sha256()
    for chunk in iter(lambda: stream.read(1024 * 1024), b''):
        size += len(chunk)
        hash_.update(chunk)
    return size, hash_.hexdigest()


def verify_image(stream, release):
    if digest(stream) != (release['bytes'], release['sha256']):
        raise ValueError('DMG does not match signed size/hash')


def publish(client, bucket, directory, public_key):
    directory = Path(directory)
    data = (directory / 'stable.json').read_bytes()
    release = manifest(data, public_key)
    image = directory / 'Bowser.dmg'
    with image.open('rb') as stream:
        verify_image(stream, release)
    previous = get(client, bucket, FEED)
    condition = {'IfNoneMatch': '*'}
    if previous:
        with closing(previous['Body']) as stream:
            old = manifest(stream.read(16385), public_key, require_fresh=False)
        if int(old['build']) > int(release['build']):
            raise ValueError('Refusing to replace a newer release')
        if old['build'] == release['build'] and (old['sha256'], old['bytes']) != (release['sha256'], release['bytes']):
            raise ValueError('A build number cannot identify different images')
        condition = {'IfMatch': previous['ETag']}
    key = f"releases/{release['build']}/Bowser.dmg"
    existing = get(client, bucket, key)
    if existing:
        with closing(existing['Body']) as stream:
            verify_image(stream, release)
    else:
        with image.open('rb') as stream:
            client.put_object(Bucket=bucket, Key=key, Body=stream, ContentLength=release['bytes'],
                              ContentType='application/x-apple-diskimage', CacheControl=IMMUTABLE,
                              ContentDisposition='attachment; filename="Bowser.dmg"', IfNoneMatch='*')
        uploaded = get(client, bucket, key)
        with closing(uploaded['Body']) as stream:
            verify_image(stream, release)
    # Keep the exact signed envelope alongside this build, including on renewals.
    client.put_object(Bucket=bucket, Key=f"releases/{release['build']}/stable.json", Body=data,
                      ContentType='application/json', CacheControl=MUTABLE)
    # A single R2 copy atomically replaces the website's stable download object.
    client.copy_object(Bucket=bucket, Key='Bowser.dmg', CopySource={'Bucket': bucket, 'Key': key},
                       MetadataDirective='REPLACE', ContentType='application/x-apple-diskimage',
                       CacheControl=MUTABLE, ContentDisposition='attachment; filename="Bowser.dmg"')
    # Promote only after the immutable image is verified; guard concurrent publishers.
    client.put_object(Bucket=bucket, Key=FEED, Body=data, ContentType='application/json',
                      CacheControl=MUTABLE, **condition)
    print(f"Published build {release['build']}: {ORIGIN}/{key}")


def main():
    import boto3
    from botocore.config import Config
    account = os.environ['R2_ACCOUNT_ID']
    if not re.fullmatch('[a-fA-F0-9]{32}', account):
        raise ValueError('R2_ACCOUNT_ID must be the Cloudflare account ID')
    client = boto3.client('s3', endpoint_url=f'https://{account}.r2.cloudflarestorage.com',
        region_name='auto', aws_access_key_id=os.environ['R2_ACCESS_KEY_ID'],
        aws_secret_access_key=os.environ['R2_SECRET_ACCESS_KEY'],
        config=Config(signature_version='s3v4', connect_timeout=30, read_timeout=300,
                      retries={'max_attempts': 3, 'mode': 'standard'},
                      request_checksum_calculation='when_required', response_checksum_validation='when_required'))
    publish(client, os.environ.get('R2_BUCKET', 'bowser'), os.environ.get('RELEASE_DIR', 'dist'),
            base64.b64decode(os.environ['BOWSER_UPDATE_PUBLIC_KEY'], validate=True))


if __name__ == '__main__':
    main()
