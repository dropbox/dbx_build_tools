"""
A Bazel target can be quarantined with by adding the `quarantined` tag.
This will allow it to be filtered out in CI, but continue to run normally in dev.

To present a uniform quarantining interface (and allow storing metadata about the quarantine),
we use a dict attribute named `quarantine`, which must be supported by all test targets.

Its value should also be set on test targets' underlying rules as well, which will enable their
values to be read through `bazel query`.

The `quarantine` attribute can contain keys:
 - `since` (required): the date on which the target was quarantined (in YYYY-MM-DD format)
 - `task` (required): a Phabricator task ID associated with the quarantine (in Tnnnnnn format)
"""

def process_quarantine_attr(quarantine):
    if not quarantine:
        return []

    required_keys = ["since", "task"]

    for key in required_keys:
        if key not in quarantine:
            fail("Missing mandatory key `%s` in quarantine attr" % (key,))

    for key in quarantine.keys():
        if key not in required_keys:
            fail("Invalid key `%s` in quarantine attr" % (key,))

    date = quarantine["since"]
    task = quarantine["task"]

    # Validate the date.
    if not (len(date) == 10 and date[:4].isdigit() and date[5:7].isdigit() and date[8:10].isdigit() and date[4] == "-" and date[7] == "-"):
        fail('"%s" is not a valid date (must be in YYYY-MM-DD format)' % (date,))

    # Validate the task ID.
    if not (task.startswith("T") and task[1:].isdigit()):
        fail('"%s" is not a valid Phabricator task ID' % (task,))

    return ["quarantined"]
