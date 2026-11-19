# A stand-in for one run of the pinned external-dns, v0.23.0, with the Cloudflare provider, against a
# zone, for the fake kubectl of tests/fixtures/cluster-dns-remove. Its input is
#   {args: [the container's arguments], zone: [{name, type, content, ttl}], marker: the zone's
#    identifier, time: the time its lines carry, token: whether the token reached the container}
# and its output {exit: the status the binary ends with, or null for one that never ends, log: [its
# lines], zone: the zone afterwards}. What it applies, each at the tag v0.23.0 of
# github.com/kubernetes-sigs/external-dns:
#   - the flags' defaults (pkg/apis/externaldns/types.go): registry txt, owner id default, no TXT
#     prefix, the record types A, AAAA and CNAME, the log format text; no policy, which
#     ValidateConfig refuses (pkg/apis/externaldns/validation/validation.go), as it does a run
#     without a source or a provider;
#   - the first line, the configuration, written before the log format is set
#     (controller/execute.go:60, :71), so in text whatever the format; every later one in the
#     format given, JSON as logrus' JSONFormatter writes it, its keys sorted;
#   - the empty source, which desires no record (source/empty.go:41-43), so the plan deletes every
#     record it reads that no source asks for (plan/plan.go:216-217), of the managed types and
#     admitted by --regex-domain-filter, once the policy has passed the deletes on, which sync does
#     and upsert-only and create-only do not (plan/policy.go:34-59), and, with the TXT registry, only
#     those whose TXT entry names the owner id (plan/plan.go:230-232, registry/txt/registry.go:387),
#     each with that entry (registry/txt/registry.go:403-405), named as the prefix makes it
#     (registry/mapper/mapper.go:95-117); the noop registry claims every record;
#   - each record changed is one line "Changing record." with action, record, ttl, type and zone
#     (provider/cloudflare/cloudflare.go:556-563), the record changed only without --dry-run
#     (cloudflare.go:566); a run with nothing to change says "All records are already up to date"
#     (controller/controller.go:131);
#   - without --once the controller keeps running (controller/execute.go:138-155); with it, one pass
#     and the status 0, or 1 after a fatal line.
# Any other source would need the Kubernetes API, which a pod without a token cannot reach, so its
# run fails; a provider other than Cloudflare, and a registry other than txt and noop, are not
# modelled and fail too. Without the token the provider refuses the run.
. as $in
| def values($flag): [$in.args[] | select(startswith("--" + $flag + "=")) | ltrimstr("--" + $flag + "=")];
  def value($flag; $default): values($flag) | if length == 0 then $default else last end;
  def given($flag): any($in.args[]; . == "--" + $flag);
  value("log-format"; "text") as $format
| def line($fields): ({level: "info", time: $in.time} + $fields)
    | if $format == "json" then to_entries | sort_by(.key) | from_entries | tojson
      else "time=\"\(.time)\" level=\(.level) msg=\"\(.msg)\""
        + ([to_entries[] | select(.key | IN("time", "level", "msg") | not) | " \(.key)=\(.value)"] | join(""))
      end;
  values("source") as $sources
| value("policy"; "") as $policy
| value("registry"; "txt") as $registry
| value("provider"; "") as $provider
| value("txt-owner-id"; "default") as $owner
| value("txt-prefix"; "") as $prefix
| (values("managed-record-types") | if length == 0 then ["A", "AAAA", "CNAME"] else . end) as $types
| value("regex-domain-filter"; "") as $filter
| given("dry-run") as $dry
| "time=\"\($in.time)\" level=info msg=\"config: {Sources:\($sources) Provider:\($provider) Policy:\($policy) Registry:\($registry) TXTOwnerID:\($owner) TXTPrefix:\($prefix) RegexDomainFilter:\($filter) ManagedDNSRecordTypes:\($types) DryRun:\($dry) Once:\(given("once"))}\"" as $config
| def fatal($message): {exit: 1, log: [$config, line({level: "fatal", msg: $message})], zone: $in.zone};
  if ($sources | length) == 0 then fatal("config validation failed: no sources specified")
  elif $provider == "" then fatal("config validation failed: no provider specified")
  elif $policy == "" then fatal("config validation failed: --policy must be set explicitly (one of: sync, upsert-only, create-only)")
  elif ($policy | IN("sync", "upsert-only", "create-only") | not) then fatal("unknown policy: \($policy)")
  elif $sources != ["empty"] then fatal("failed to list the source's objects: the pod has no token for the Kubernetes API")
  elif $provider != "cloudflare" or ($registry | IN("txt", "noop") | not) then fatal("not modelled by the stand-in: provider \($provider), registry \($registry)")
  elif ($in.token | not) then fatal("failed to list zones: Invalid request headers (Code: 6003)")
  elif given("once") | not then {exit: null, log: [$config], zone: $in.zone}
  else
    def admitted: $filter == "" or test($filter);
    def txt_name($record): ($record.name | split(".")) as $labels
      | ($record.type | ascii_downcase) as $type
      | ($labels[1:] | join(".")) as $rest
      | if ($prefix | contains("%{record_type}"))
        then ($prefix | gsub("%\\{record_type\\}"; $type)) + $labels[0] + (if $rest == "" then "" else "." + $rest end)
        else $prefix + $type + "-" + $labels[0] + (if $rest == "" then "" else "." + $rest end) end;
    def owner($record): txt_name($record) as $txt
      | [$in.zone[] | select(.type == "TXT" and .name == $txt) | .content | ltrimstr("\"") | rtrimstr("\"")
          | select(startswith("heritage=external-dns,")) | capture("external-dns/owner=(?<owner>[^,]*)").owner] | first;
    [$in.zone[] | select(.type as $type | $types | index($type)) | select(.name | admitted)] as $managed
    | (if $policy != "sync" then []
       elif $registry == "noop" then $managed
       else [$managed[] | select(owner(.) == $owner)] end) as $records
    | (if $registry == "txt" then [$records | map(txt_name(.)) | unique[] as $txt | $in.zone[] | select(.type == "TXT" and .name == $txt)] else [] end) as $entries
    | ($records + $entries) as $changes
    | {exit: 0,
       log: ([$config]
         + (if $dry then [line({msg: "running in dry-run mode. No changes to DNS records will be made."})] else [] end)
         + (if ($changes | length) == 0 then [line({msg: "All records are already up to date"})]
            else [$changes[] | line({msg: "Changing record.", action: "DELETE", record: .name, ttl: .ttl, type: .type, zone: $in.marker})] end)),
       zone: (if $dry then $in.zone else [$in.zone[] | select(. as $record | $changes | index([$record]) | not)] end)}
  end
