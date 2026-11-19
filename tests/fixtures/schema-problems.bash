# The check of a custom resource against its definition's schema, for the tests that hold a
# manifest to the pinned chart's definition. Loaded with `load fixtures/schema-problems` from a test
# file.
#
# schema_problems SCHEMA DOCUMENT: what is wrong with the JSON DOCUMENT against the JSON schema file
# SCHEMA, one line each: a field the schema does not define, a value of another type than its field's
# or outside its enum. Each value's place in the schema: a property, an array's items, a map's
# additionalProperties, or anything at all below a field that keeps unknown fields. Metadata is the
# API server's. Every path counts, those of maps and lists and of false and null values included:
# paths(scalars) would drop the last two, and an empty map or list has no path below it.
schema_problems() {
  jq -r --slurpfile schema "$1" '
    def node($s; $p): reduce $p[] as $k ($s;
      if . == null or .["x-any"] then .
      elif ($k | type) == "number" then .items
      elif ((.properties // {}) | has($k)) then .properties[$k]
      elif (.additionalProperties | type) == "object" then .additionalProperties
      elif .["x-kubernetes-preserve-unknown-fields"] then {"x-any": true}
      else null end);
    def types($n): if $n["x-kubernetes-int-or-string"] then ["integer", "string"]
      elif $n.type then [$n.type] else [($n.anyOf // [])[].type | select(. != null)] end;
    def kind: if type == "number" then (if . == floor then "integer" else "number" end) else type end;
    def shown: if type == "object" then "a map" elif type == "array" then "a list" else tojson end;
    . as $doc | $schema[0] as $s
    | paths as $p | select($p[0] != "apiVersion" and $p[0] != "kind" and $p[0] != "metadata")
    | ($doc | getpath($p)) as $v | node($s; $p) as $n | ($p | map(tostring) | join(".")) as $at
    | if $n == null then "\($at): not in the definition"
      elif $n["x-any"] then empty
      elif (types($n) | length) > 0 and (any(types($n)[]; . == ($v | kind) or (. == "number" and ($v | kind) == "integer")) | not)
        then "\($at): \($v | shown) is not of type \(types($n) | join(" or "))"
      elif ($v | type) != "object" and ($v | type) != "array" and $n.enum != null and (any($n.enum[]; . == $v) | not)
        then "\($at): \($v | tojson) is not one of \($n.enum | tojson)"
      else empty end' "$2"
}
