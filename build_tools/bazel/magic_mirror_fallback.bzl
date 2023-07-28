MAGIC_MIRROR_URL_MAPPING = {
    "dbx-artifactory-primary.awsvip.dbxnw.net/artifactory/python-local": "forge-magic-mirror.awsvip.dbxnw.net/python-mirror",
    "dbx-artifactory-primary.awsvip.dbxnw.net/artifactory/python-local-index": "forge-magic-mirror.awsvip.dbxnw.net/python-mirror-index",
    "dbx-artifactory-primary.awsvip.dbxnw.net/artifactory/archives-local": "forge-magic-mirror.awsvip.dbxnw.net/archives",
    "dbx-artifactory-primary.awsvip.dbxnw.net/artifactory/golang-local": "forge-magic-mirror.awsvip.dbxnw.net/golang-mirror",
    "dbx-artifactory-primary.awsvip.dbxnw.net/artifactory/npm-local": "forge-magic-mirror.awsvip.dbxnw.net/node-mirror",
}

MAGIC_MIRROR_FALLBACK_PYTHON = True
MAGIC_MIRROR_FALLBACK_NODE = True

# the follow settings automatically fallback to Magic Mirror, but we should still trigger them to relieve load against Artifactory if needed
MAGIC_MIRROR_FALLBACK_GO = True
MAGIC_MIRROR_FALLBACK_ARCHIVES = True
