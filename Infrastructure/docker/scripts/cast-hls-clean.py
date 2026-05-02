#!/usr/bin/env python3
import boto3, os, time
from concurrent.futures import ThreadPoolExecutor, as_completed

BUCKET     = os.environ["R2_BUCKET"]
ENDPOINT   = os.environ["R2_ENDPOINT"]
ACCESS_KEY = os.environ["R2_ACCESS_KEY"]
SECRET_KEY = os.environ["R2_SECRET_KEY"]
HLS_BASE   = os.environ.get("HLS_BASE", "/var/lib/mistserver/hls")
MAX_AGE_S  = int(os.environ.get("HLS_MAX_AGE_S", "120"))

client = boto3.client('s3', endpoint_url=ENDPOINT,
                      aws_access_key_id=ACCESS_KEY,
                      aws_secret_access_key=SECRET_KEY,
                      region_name='auto')

def delete_key(key):
    client.delete_object(Bucket=BUCKET, Key=key)
    return key

now = time.time()
cutoff = now - MAX_AGE_S

streams = [d for d in os.listdir(HLS_BASE) if os.path.isdir(os.path.join(HLS_BASE, d))]

for stream in streams:
    prefix = f"live/{stream}"
    hls_dir = os.path.join(HLS_BASE, stream)

    to_delete = []
    paginator = client.get_paginator('list_objects_v2')
    for page in paginator.paginate(Bucket=BUCKET, Prefix=prefix + '/'):
        for obj in page.get('Contents', []):
            key = obj['Key']
            if not key.endswith('.ts'):
                continue
            if obj['LastModified'].timestamp() < cutoff:
                to_delete.append(key)

    if not to_delete:
        print(f'[cleanup:{stream}] nothing to delete in R2')
    else:
        print(f'[cleanup:{stream}] deleting {len(to_delete)} old segments from R2')
        with ThreadPoolExecutor(max_workers=16) as pool:
            futures = {pool.submit(delete_key, k): k for k in to_delete}
            errors = 0
            for fut in as_completed(futures):
                try:
                    fut.result()
                except Exception as e:
                    errors += 1
                    print(f'[cleanup:{stream}] error: {e}')
            print(f'[cleanup:{stream}] done. deleted={len(to_delete)-errors} errors={errors}')

    local_deleted = 0
    for fname in os.listdir(hls_dir):
        if not fname.endswith('.ts'):
            continue
        fpath = os.path.join(hls_dir, fname)
        try:
            if os.path.getmtime(fpath) < cutoff:
                os.unlink(fpath)
                local_deleted += 1
        except OSError:
            pass
    print(f'[cleanup:{stream}] local segments deleted: {local_deleted}')
