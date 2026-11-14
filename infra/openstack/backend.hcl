# The S3 backend settings every stack is initialised with: the cloud's S3-compatible object
# storage in sto2. scripts/stack-env adds the bucket (TF_STATE_BUCKET) and a state key derived from
# the stack's path; the credentials come from AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY.
# The store is not AWS: the region only satisfies the S3 client, buckets are addressed by path, and
# the AWS-only credential, account, metadata, region and checksum steps are skipped.
region = "us-east-1"
endpoints = {
  s3 = "https://s3-sto2.citycloud.com"
}
use_path_style              = true
skip_credentials_validation = true
skip_requesting_account_id  = true
skip_metadata_api_check     = true
skip_region_validation      = true
skip_s3_checksum            = true
# Native state locking (use_lockfile = true) is switched on here once this store is shown to honour
# it. Until then the recipes take a local lock per stack, and stacks are applied one at a time.
