#!/usr/bin/env python3
"""Delete one generation of a Cloud Storage object with an HMAC key.

    hmac-rm-generation.py BUCKET/KEY GENERATION

Reads AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY (the HMAC key of the
upload identity) and sends DELETE ...?generation=N to the XML API,
signed with SigV4. This is the request a retention policy has to
refuse for the upload identity; `offload-drill.sh lock-test --gs` makes
the same request as whoever gcloud is logged in as.

The S3 route does not work for this: Cloud Storage lists versions over
the S3 API without a VersionId, so `aws s3api delete-object
--version-id` has nothing to pass.

Prints the HTTP status and the error body. Exit 0 when the delete was
refused (the data is safe), 1 when it went through.
Needs botocore (pip install botocore, or the copy inside awscli).
"""
import os
import sys
import urllib.error
import urllib.request

try:
    from botocore.auth import S3SigV4Auth
    from botocore.awsrequest import AWSRequest
    from botocore.credentials import Credentials
except ImportError:
    from awscli.botocore.auth import S3SigV4Auth
    from awscli.botocore.awsrequest import AWSRequest
    from awscli.botocore.credentials import Credentials


def main():
    if len(sys.argv) != 3:
        print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
        return 2
    path, gen = sys.argv[1], sys.argv[2]
    url = f"https://storage.googleapis.com/{path}?generation={gen}"
    req = AWSRequest(method="DELETE", url=url)
    creds = Credentials(os.environ["AWS_ACCESS_KEY_ID"], os.environ["AWS_SECRET_ACCESS_KEY"])
    # x-amz-content-sha256 is required; S3SigV4Auth adds it
    S3SigV4Auth(creds, "s3", "auto").add_auth(req)
    http = urllib.request.Request(url, method="DELETE", headers=dict(req.headers))
    try:
        with urllib.request.urlopen(http) as resp:
            print(f"HTTP {resp.status}: generation {gen} deleted")
            return 1
    except urllib.error.HTTPError as e:
        print(f"HTTP {e.code}: {e.read().decode(errors='replace')}")
        return 0


if __name__ == "__main__":
    sys.exit(main())
