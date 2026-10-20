"""Generate a seeded, fully synthetic labeled corpus for comparing PHI detectors.

Every value is synthetic: names are drawn from generic first/last lists,
emails use example.invalid, phones use the 555-01xx range, SSNs use the
never-issued 9xx area. Each sample records gold character spans per category.

Output: corpus.jsonl, one object per sample:
  id, kind (handoff|diff|output), shape (template family), bucket
  (phi|clean|clinical-only), text, spans [{cat, start, end}]
"""

import json
import random
import re
import sys

SEED = 20261020
rng = random.Random(SEED)

FIRST = ["Maria", "Daniel", "Priya", "Tomas", "Aisha", "Wei", "Grace", "Omar",
         "Elena", "Marcus", "Hana", "Luis", "Fatima", "Noah", "Ingrid", "Kofi"]
LAST = ["Okafor", "Lindqvist", "Ramirez", "Nakamura", "Haddad", "Brennan",
        "Petrov", "Achebe", "Moreau", "Castellano", "Whitlock", "Sorensen"]
STREETS = ["Harbor View", "Maple", "Juniper Hill", "Old Mill", "Cedar Ridge",
           "Larkspur", "Willow Bend", "Quarry"]
SUFFIX_LISTED = ["Street", "St", "Avenue", "Ave", "Road", "Rd", "Drive", "Lane"]
SUFFIX_UNLISTED = ["Court", "Way", "Terrace", "Place", "Circle", "Parkway"]
CITIES = ["Springfield", "Riverton", "Fairview", "Lakeside", "Brookhaven"]
MONTHS = ["January", "February", "March", "April", "May", "June", "July",
          "August", "September", "October", "November", "December"]
DX = ["type 2 diabetes", "major depressive disorder", "hypertension",
      "hypothyroidism", "chronic kidney disease stage 3", "asthma"]
MEDS = ["metformin 500 mg", "sertraline 50 mg", "lisinopril 10 mg",
        "levothyroxine 75 mcg", "atorvastatin 20 mg", "testosterone cypionate 100 mg"]
LABS = ["A1c 8.2%", "TSH 6.1 mIU/L", "eGFR 48", "LDL 162 mg/dL", "total testosterone 212 ng/dL"]


def person():
    return f"{rng.choice(FIRST)} {rng.choice(LAST)}"


def first():
    return rng.choice(FIRST)


def last():
    return rng.choice(LAST)


def dob_iso():
    return f"19{rng.randint(40, 99)}-{rng.randint(1, 12):02d}-{rng.randint(1, 28):02d}"


def dob_us():
    return f"{rng.randint(1, 12)}/{rng.randint(1, 28)}/19{rng.randint(40, 99)}"


def dob_words():
    return f"{rng.choice(MONTHS)} {rng.randint(1, 28)}, 19{rng.randint(40, 99)}"


def dob_compact():
    return f"{rng.randint(1, 28)} {rng.choice(MONTHS)[:3]} 19{rng.randint(40, 99)}"


def ssn():
    return f"9{rng.randint(0, 99):02d}-{rng.randint(10, 99)}-{rng.randint(1000, 9999)}"


def ssn_bare():
    return f"9{rng.randint(0, 99):02d}{rng.randint(10, 99)}{rng.randint(1000, 9999)}"


def mrn_short():
    return f"{rng.choice('ABCDEFGH')}{rng.randint(100000, 999999)}"


def mrn_long():
    return str(rng.randint(10**9, 10**10 - 1))


def member_id():
    return f"{rng.choice(['XKQ', 'ZPA', 'HMB'])}{rng.randint(10000000, 99999999)}"


def phone():
    return f"{rng.randint(201, 989)}-555-01{rng.randint(10, 99)}"


def phone_paren():
    return f"({rng.randint(201, 989)}) 555-01{rng.randint(10, 99)}"


def phone_intl():
    return f"+1 {rng.randint(201, 989)} 555 01{rng.randint(10, 99)}"


def email():
    return f"{first().lower()}.{last().lower()}{rng.randint(1, 99)}@example.invalid"


def addr_listed():
    return f"{rng.randint(10, 9999)} {rng.choice(STREETS)} {rng.choice(SUFFIX_LISTED)}"


def addr_unlisted():
    return f"{rng.randint(10, 9999)} {rng.choice(STREETS)} {rng.choice(SUFFIX_UNLISTED)}"


def addr_unit():
    return f"Unit {rng.randint(1, 40)}{rng.choice('ABCD')}, {rng.choice(STREETS)} {rng.choice(SUFFIX_UNLISTED)}, {rng.choice(CITIES)}"


def zipcode():
    return f"{rng.randint(10000, 99999)}"


def dx():
    return rng.choice(DX)


def med():
    return rng.choice(MEDS)


def lab():
    return rng.choice(LABS)


# placeholder -> (gold category or None for unlabeled filler, generator)
GEN = {
    "person": ("person", person), "first": ("person", first), "last": ("person", last),
    "dob_iso": ("date", dob_iso), "dob_us": ("date", dob_us),
    "dob_words": ("date", dob_words), "dob_compact": ("date", dob_compact),
    "ssn": ("id", ssn), "ssn_bare": ("id", ssn_bare),
    "mrn_short": ("id", mrn_short), "mrn_long": ("id", mrn_long), "member_id": ("id", member_id),
    "phone": ("phone", phone), "phone_paren": ("phone", phone_paren), "phone_intl": ("phone", phone_intl),
    "email": ("email", email),
    "addr_listed": ("address", addr_listed), "addr_unlisted": ("address", addr_unlisted),
    "addr_unit": ("address", addr_unit), "zip": ("address", zipcode),
    "dx": ("clinical", dx), "med": ("clinical", med), "lab": ("clinical", lab),
}

LONG_HANDOFF = (
    "## Summary\n\nFixed the refill job double-charging when a pharmacy transfer lands mid-cycle. "
    "The job now takes a row lock on the order before it charges, and skips orders whose "
    "transfer is still pending.\n\n## Changes\n\n- app/jobs/refill_job.rb: lock the order, skip pending transfers\n"
    "- app/models/order.rb: add Order#transfer_pending?\n- spec/jobs/refill_job_spec.rb: cover the lock and the skip\n\n"
    "## Data\n\nRan the backfill against 37 affected orders; 36 were refunded automatically. {extra}"
    "Nothing else needed a data change.\n\n## Tests\n\nbundle exec rspec spec/jobs spec/models: 214 examples, 0 failures.\n\n"
    "## Follow-up\n\nThe transfer webhook can still arrive twice; tracked separately."
)

# (kind, shape, bucket, template). kind decides the phi-scan profile, the way
# delegate.sh and collect.sh use it: handoff/output -> default, diff -> diff.
TEMPLATES = [
    # --- PHI, prose handoffs: names and dates in sentences ---
    ("handoff", "prose-name", "phi",
     "Fixed the duplicate refill for {person}. Their order had two active subscriptions; I cancelled the newer one and left a note."),
    ("handoff", "prose-name", "phi",
     "Root cause: {person} changed pharmacies mid-cycle, so the transfer job ran twice. Backfilled the missing shipment record."),
    ("handoff", "prose-name-dob-words", "phi",
     "Merged the two accounts for {person} (born {dob_words}). The older account kept the lab history."),
    ("handoff", "prose-name-dob-compact", "phi",
     "Patient {person}, DOB {dob_compact}, had a stale intake form; regenerated it."),
    ("handoff", "prose-first-dx", "phi",
     "{first} was flagged for follow-up because of {dx}; the reminder email never sent. Re-queued it."),
    ("handoff", "prose-name-med", "phi",
     "Verified that {person} is on {med} and the prescription renewal now routes to the right provider."),
    ("handoff", "prose-contact", "phi",
     "Reached out to {person} at {email} and {phone} to confirm the new shipping address."),
    ("handoff", "prose-address-unlisted", "phi",
     "Updated the shipping address to {addr_unlisted}, {zip} after the carrier bounced it."),
    ("handoff", "prose-address-unit", "phi",
     "Carrier could not deliver to {addr_unit}; marked the order for manual review."),
    ("handoff", "prose-address-listed", "phi",
     "Address on file was {addr_listed}; the geocoder had it in the wrong county."),
    ("handoff", "prose-mrn-short", "phi",
     "Chart {mrn_short} had two primary providers assigned; removed the inactive one."),
    ("handoff", "prose-mrn-labeled", "phi",
     "MRN {mrn_short} was missing from the sync; reran the export for that record only."),
    ("handoff", "prose-member", "phi",
     "Insurance eligibility for member {member_id} failed because the payer changed the group number."),
    ("handoff", "prose-ssn", "phi",
     "Found an SSN ({ssn}) stored in the notes field; moved it to the encrypted column."),
    ("handoff", "prose-lab-name", "phi",
     "{person}'s {lab} result was attached to the wrong encounter; moved it."),
    ("handoff", "prose-dob-us", "phi",
     "The record with DOB {dob_us} failed age validation because of a timezone shift."),
    ("handoff", "prose-phone-intl", "phi",
     "SMS to {phone_intl} kept failing; the number was stored without the country code."),
    # --- PHI, tool output: query results and records ---
    ("output", "psql-row", "phi",
     " id   | first_name | last_name | dob        | phone\n------+------------+-----------+------------+--------------\n 1042 | {first}    | {last}    | {dob_iso} | {phone}\n(1 row)"),
    ("output", "csv-row", "phi",
     "patient_id,name,birth_date,email\n{mrn_short},{person},{dob_iso},{email}"),
    ("output", "json-record", "phi",
     '{"first_name": "{first}", "last_name": "{last}", "date_of_birth": "{dob_iso}", "member_id": "{member_id}"}'),
    ("output", "json-record-noid", "phi",
     '{"name": "{person}", "address": "{addr_unlisted}", "zip": "{zip}"}'),
    ("output", "rails-inspect", "phi",
     '#<Patient id: 88231, first_name: "{first}", last_name: "{last}", dob: "{dob_iso}", ssn_last4: "4821">'),
    ("output", "log-line", "phi",
     "INFO  Sending reminder to {email} for patient {person} (dx: {dx})"),
    ("output", "log-ssn-bare", "phi",
     "WARN  payload contained unmasked tax id {ssn_bare}"),
    ("output", "log-mrn-long", "phi",
     "ERROR lookup failed for record {mrn_long}: no matching encounter"),
    # --- PHI, diffs: fixtures or seeds with real-looking records ---
    ("diff", "diff-fixture", "phi",
     "diff --git a/spec/fixtures/patient.json b/spec/fixtures/patient.json\nindex 1a2b3c4..5d6e7f8 100644\n--- a/spec/fixtures/patient.json\n+++ b/spec/fixtures/patient.json\n@@ -1,3 +1,6 @@\n {\n+  \"name\": \"{person}\",\n+  \"dob\": \"{dob_iso}\",\n+  \"phone\": \"{phone}\"\n }"),
    ("diff", "diff-seed-name", "phi",
     "diff --git a/db/seeds.rb b/db/seeds.rb\nindex 1a2b3c4..5d6e7f8 100644\n--- a/db/seeds.rb\n+++ b/db/seeds.rb\n@@ -10,2 +10,3 @@\n users = []\n+users << User.create!(name: \"{person}\", address: \"{addr_unlisted}\")\n puts users.size"),
    ("diff", "diff-comment-name", "phi",
     "diff --git a/app/jobs/refill_job.rb b/app/jobs/refill_job.rb\nindex 1a2b3c4..5d6e7f8 100644\n--- a/app/jobs/refill_job.rb\n+++ b/app/jobs/refill_job.rb\n@@ -4,2 +4,3 @@\n def perform(id)\n+  # skip {person} until the pharmacy transfer clears\n   order = Order.find(id)"),

    # --- clinical-only: medical detail with no identifier ---
    ("handoff", "clinical-only", "clinical-only",
     "The dosing calculator rounded {med} incorrectly for patients with {dx}; fixed the rounding."),
    ("output", "clinical-only", "clinical-only",
     "count by diagnosis: {dx} = 412, other = 1980"),

    # --- clean: ordinary engineering text that must not be withheld ---
    ("handoff", "clean-ops", "clean",
     "Restarted the worker service; queue depth dropped from 1,204 to 0 within five minutes. No data changes."),
    ("handoff", "clean-ops-arn", "clean",
     "Updated arn:aws:ecs:us-east-1:123456789012:service/app/worker to task revision 87."),
    ("handoff", "clean-feature-prose", "clean",
     "Added validation so the date of birth field rejects future dates, and a migration for the MRN index."),
    ("handoff", "clean-feature-prose", "clean",
     "The prescription renewal flow now checks dosage limits server side. Tests cover the diagnosis picker."),
    ("handoff", "clean-ticket", "clean",
     "Closed out the ticket: the export job now pages after 500 rows and finishes in 40 seconds."),
    ("handoff", "clean-timestamps", "clean",
     "Deploy finished at 2026-10-19 14:32 UTC; the next cron run is 2026-10-20T02:00:00Z."),
    ("handoff", "clean-versions", "clean",
     "Bumped rails from 7.1.3 to 7.2.1 and node from 20.11.0 to 22.4.1; lockfile regenerated."),
    ("output", "clean-ci-log", "clean",
     "PASS spec/models/order_spec.rb (412 examples, 0 failures)\nFinished in 38.21 seconds (files took 2.9 seconds to load)"),
    ("output", "clean-uuid", "clean",
     "request_id=7f9c2b1e-4a6d-4c3b-9e8f-1a2b3c4d5e6f status=200 duration_ms=184"),
    ("output", "clean-counts", "clean",
     " status    | count\n-----------+-------\n active    | 18234\n cancelled |  2210\n(2 rows)"),
    ("output", "clean-sha", "clean",
     "HEAD is now at 6a088eb4c2d1 Say a flagged prompt got no answer"),
    ("diff", "clean-code", "clean",
     "diff --git a/app/models/order.rb b/app/models/order.rb\nindex 1a2b3c4..5d6e7f8 100644\n--- a/app/models/order.rb\n+++ b/app/models/order.rb\n@@ -12,3 +12,4 @@\n   def total\n-    items.sum(&:price)\n+    items.sum(&:price) - discount\n   end"),
    ("diff", "clean-code-fieldnames", "clean",
     "diff --git a/app/serializers/patient_serializer.rb b/app/serializers/patient_serializer.rb\nindex 1a2b3c4..5d6e7f8 100644\n--- a/app/serializers/patient_serializer.rb\n+++ b/app/serializers/patient_serializer.rb\n@@ -3,2 +3,3 @@\n   attributes :id, :email\n+  attribute :first_name\n+  attribute :dob"),
    ("diff", "clean-code-assign", "clean",
     "diff --git a/app/forms/intake_form.rb b/app/forms/intake_form.rb\nindex 1a2b3c4..5d6e7f8 100644\n--- a/app/forms/intake_form.rb\n+++ b/app/forms/intake_form.rb\n@@ -8,2 +8,3 @@\n   def assign(params)\n+    self.first_name = params[:first_name]\n   end"),
    ("diff", "clean-migration", "clean",
     "diff --git a/db/migrate/20261019_add_index.rb b/db/migrate/20261019_add_index.rb\nnew file mode 100644\n--- /dev/null\n+++ b/db/migrate/20261019_add_index.rb\n@@ -0,0 +1,5 @@\n+class AddIndex < ActiveRecord::Migration[7.2]\n+  def change\n+    add_index :patients, :date_of_birth\n+  end\n+end"),
    ("diff", "clean-commit-trailer", "clean",
     "commit 6a088eb4c2d1e5f6a7b8c9d0e1f2a3b4c5d6e7f8\nAuthor: Dev Example <dev@example.invalid>\nDate:   Mon Oct 19 14:32:10 2026 -0500\n\n    Tighten the export pager\n\n    Co-Authored-By: Reviewer Example <reviewer@example.invalid>\n\ndiff --git a/app/jobs/export_job.rb b/app/jobs/export_job.rb\nindex 1a2b3c4..5d6e7f8 100644\n--- a/app/jobs/export_job.rb\n+++ b/app/jobs/export_job.rb\n@@ -2,1 +2,1 @@\n-  BATCH = 1000\n+  BATCH = 500"),
    ("diff", "clean-test-placeholder", "clean",
     "diff --git a/spec/models/user_spec.rb b/spec/models/user_spec.rb\nindex 1a2b3c4..5d6e7f8 100644\n--- a/spec/models/user_spec.rb\n+++ b/spec/models/user_spec.rb\n@@ -1,2 +1,3 @@\n describe User do\n+  let(:user) { build(:user, email: \"user@example.invalid\") }\n end"),

    # --- round 2: realistic engineering text, so the clean side is not thin ---
    ("handoff", "clean-long-handoff", "clean", LONG_HANDOFF.format(extra="")),
    ("handoff", "clean-eponym-prose", "clean",
     "Added Hashimoto's thyroiditis and Addison's disease to the condition picker; the Graves' disease code was already mapped."),
    ("handoff", "clean-region-prose", "clean",
     "Moved the worker from us-east-1 to us-west-2 and pointed api.example.invalid at the new load balancer."),
    ("output", "clean-stacktrace", "clean",
     "NoMethodError: undefined method `total' for nil\n  app/models/order.rb:42:in `charge'\n  app/jobs/refill_job.rb:18:in `perform'\n  /usr/local/bundle/gems/sidekiq-7.2.4/lib/sidekiq/processor.rb:202:in `execute_job'"),
    ("output", "clean-sql-text", "clean",
     "SELECT id, first_name, dob FROM patients WHERE updated_at > $1 ORDER BY id LIMIT 500;"),
    ("output", "clean-git-oneline", "clean",
     "6a088eb Say a flagged prompt got no answer\n37e4f38 Scope output scrubbing to data paths\nc39c567 Set guardrail on explicitly\n66c05a0 Keep the guardrail opt-in"),
    ("output", "clean-rspec", "clean",
     "Randomized with seed 48213\n........F...\n\nFailures:\n  1) Order#total subtracts the discount\n     Failure/Error: expect(order.total).to eq(90)\n\n12 examples, 1 failure"),
    ("output", "clean-yaml", "clean",
     "service: worker\nregion: us-east-1\nreplicas: 3\nimage: app:2026.10.19-1432\nhealthcheck:\n  path: /up\n  interval: 30"),
    ("diff", "clean-factory-placeholder", "clean",
     "diff --git a/spec/factories/patients.rb b/spec/factories/patients.rb\nindex 1a2b3c4..5d6e7f8 100644\n--- a/spec/factories/patients.rb\n+++ b/spec/factories/patients.rb\n@@ -1,3 +1,4 @@\n factory :patient do\n   first_name { \"Test\" }\n+  last_name { \"Patient\" }\n end"),
    ("diff", "clean-lockfile", "clean",
     "diff --git a/package-lock.json b/package-lock.json\nindex 1a2b3c4..5d6e7f8 100644\n--- a/package-lock.json\n+++ b/package-lock.json\n@@ -210,3 +210,3 @@\n     \"node_modules/zod\": {\n-      \"version\": \"3.23.8\",\n+      \"version\": \"3.24.1\",\n       \"integrity\": \"sha512-XBx9AXhXktjUqnepgTiE5flcKIYWi/rme0Eaj+5Y0lftuGBq+jyRu/md4WnuxqgP1ubdpNCsYEYPxrzVHD8d6g==\""),
    # staff names: workforce, not patients, so not PHI; scored as clean to show
    # what a person-label gate costs on ordinary handoffs
    ("handoff", "clean-staff-name", "clean",
     "Paired with {person} from the platform team on the queue fix; they will watch the alerts tonight."),

    # --- round 2: PHI buried in a long, mostly clean handoff ---
    ("handoff", "long-buried-name", "phi", LONG_HANDOFF.format(extra="One order belonged to {person}; I left that one for support. ")),
    ("handoff", "long-buried-mrn", "phi", LONG_HANDOFF.format(extra="Chart {mrn_short} still needs a manual check. ")),
    ("handoff", "long-buried-dob", "phi", LONG_HANDOFF.format(extra="The odd one out was born {dob_words}. ")),
]

PLACEHOLDER = re.compile(r"\{(\w+)\}")
REPEATS = {"phi": 8, "clinical-only": 6, "clean": 5}


def fill(template):
    out, spans, pos = [], [], 0
    for m in PLACEHOLDER.finditer(template):
        key = m.group(1)
        if key not in GEN:
            continue
        out.append(template[pos:m.start()])
        cat, gen = GEN[key]
        value = gen()
        start = sum(len(s) for s in out)
        out.append(value)
        spans.append({"cat": cat, "start": start, "end": start + len(value)})
        pos = m.end()
    out.append(template[pos:])
    return "".join(out), spans


def main(path):
    n = 0
    with open(path, "w") as f:
        for t_idx, (kind, shape, bucket, tmpl) in enumerate(TEMPLATES):
            for r in range(REPEATS[bucket]):
                text, spans = fill(tmpl)
                f.write(json.dumps({"id": f"{shape}-{t_idx}-{r}", "kind": kind, "shape": shape,
                                    "bucket": bucket, "text": text, "spans": spans}) + "\n")
                n += 1
    print(f"wrote {n} samples to {path}", file=sys.stderr)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "corpus.jsonl")
