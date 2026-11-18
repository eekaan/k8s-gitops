#!/usr/bin/env bats
# Proves features/dashboards.feature; each test carries its scenario's title.
# Needs helm, kustomize, flux, yq, jq, awk, cmp, tar and sha256sum on PATH (the versions pinned for the
# repository). Each chart is pulled once per run from its public registry; building and rendering
# are offline, and no dashboard is fetched: every upstream file a dashboard comes from is committed
# in the tree and recorded, so a check never reads one from the network.
#
# What the check of the metrics reads, and what it cannot see (docs/kubernetes.md, Dashboards, says
# the same):
#   - It is by name. Which target serves a metric is the claim of the table,
#     tests/fixtures/dashboards/metric-sources.tsv; label matchers are not checked, but for the job
#     matchers of the dashboards written for this tree, in any of PromQL's quotes, and the label the
#     Cilium dashboard selects by; and a metric a feature would emit passes while the feature is off.
#     An expression that names a metric or a label in quotes, as Prometheus 3 allows, is refused: a
#     quoted label may be __name__ or job.
#   - A metric name a variable completes is read only where the variable holds one fixed text, a
#     constant or a text box with a default, which is put in its place. A name any other variable
#     completes or stands for is not read, nor is a selector that matches __name__ by anything but =
#     and a literal: the table pins how many such expressions a dashboard has, with the reason, and a
#     dashboard written for this tree may have none. A variable stands for a name wherever it stands
#     outside a string, a range, a label list and an offset, but for Grafana's own, $__...: inside a
#     selector's braces too, as a whole matcher, a label's name or a value without quotes, as Grafana
#     puts a whole matcher a variable holds in as it is; one that stands for a number, as the first
#     argument of topk, is counted as one that stands for a name. A dashboard that defines a variable
#     of such a name is refused, and one written for this tree, the home among them, defines none but
#     its datasource. A variable inside a string is read as the string: Grafana escapes no double
#     quote of a variable's value, so in an upstream file, which its hash pins, a value with one may
#     end the string, and what follows it is not read.
#   - A series a recording rule of the render writes needs no row, and what the rule reads is not
#     followed.
#   - A target whose datasource is not Prometheus is not read, as the logs dashboard's LogsQL is not,
#     nor are the dashboards of the monitoring chart, which tests/grafana.bats holds to the chart and
#     its values. The datasource is the one Grafana finds: by the uid or name a reference gives, and
#     by its type only where it gives no uid; one the check cannot place is read.
#   - A variable's query is read as label_values(<selector>, <label>), query_result(<query>) or a
#     selector, as a string or under .query; label_values(<label>) and label_names() name no metric;
#     any other form is refused, naming the variable.
#   - A monitor drops a metric when a metricRelabelings rule on __name__ alone, of any of its
#     endpoints, of action drop matches the whole name or of action keep does not, whatever the case
#     of the action; a rule that gives no regex has Prometheus' default, (.*). A rule on more labels
#     than the name is not read.

# The tests run one at a time even where bats runs a file's tests side by side: a test that starts
# while another pulls a chart finds the chart's directory before the chart is in it.
export BATS_NO_PARALLELIZE_WITHIN_FILE=true

# Every application that delivers a dashboard, each a directory of apps/base with a
# grafanadashboard*.yaml in its app/, sorted. A new one is added here on purpose, with its place in
# docs/kubernetes.md (Dashboards).
DASHBOARD_APPS="cert-manager-dashboard cilium-monitoring-dashboard cloudnative-pg-dashboard external-dns-dashboard falco-dashboard flux-monitoring-dashboard grafana linstor-monitoring-dashboard openbao-dashboard silence-operator-dashboard victoria-logs"

# The dashboards written for this tree that an application other than the Grafana's delivers, by
# the name of their GrafanaDashboard, sorted. Every other dashboard outside the Grafana application
# is an upstream file and carries its records, so one cannot pass as the tree's by losing them.
OWN_DASHBOARDS="cert-manager cilium-bgp external-dns flux silence-operator"

# The upstream dashboards whose file the pinned chart's archive carries, by name, sorted: each
# records the file's path in the chart as Chart-path and is compared with it byte for byte.
CHART_CARRIED="cilium-agent cloudnative-pg falco openbao"

# The repository each upstream dashboard is taken from, by name, sorted: its Source is a file of that
# repository, so a copy in another repository, at the same tag and path, is not taken for it.
UPSTREAM_REPOSITORIES="cilium-agent=https://github.com/cilium/cilium cloudnative-pg=https://github.com/cloudnative-pg/grafana-dashboards falco=https://github.com/falcosecurity/charts openbao=https://github.com/openbao/openbao-helm piraeus=https://github.com/piraeusdatastore/piraeus-operator victoria-logs=https://github.com/VictoriaMetrics/VictoriaLogs"
# And the path of its file in that repository, by name, sorted: its Source is that file at a tag, so
# another file of the repository is not taken for it, where no Chart-path ties the record to the file.
UPSTREAM_PATHS="cilium-agent=install/kubernetes/cilium/files/cilium-agent/dashboards/cilium-dashboard.json cloudnative-pg=charts/cluster/grafana-dashboard.json falco=charts/falco/dashboards/falco-dashboard.json openbao=charts/openbao/grafana/dashboards/dashboard.json piraeus=config/extras/monitoring/piraeus-dashboard.json victoria-logs=dashboards/victorialogs.json"

# The licences an upstream dashboard may have to be copied into this tree, which is Apache-2.0.
LICENCES="Apache-2.0 BSD-2-Clause BSD-3-Clause MIT MPL-2.0"

# The panel types Grafana 13 ships (the ids of public/app/plugins/panel/*/plugin.json at v13.1.3,
# and row, which is no plugin), and those it turns into one of them when it loads a dashboard
# (autoMigrateAngular in public/app/features/dashboard/state/PanelModel.ts and
# getPanelPluginToMigrateTo.ts beside it; GetAngularPanelMigration in
# apps/dashboard/pkg/migration/schemaversion/migration_utils.go). A panel of any other type needs a
# plugin, which nothing installs.
PANEL_TYPES="alertlist annolist barchart bargauge candlestick canvas dashlist debug flamegraph gauge geomap gettingstarted heatmap histogram live logs logstable news nodeGraph piechart row stat state-timeline status-history table text timeseries traces trend welcome xychart"
MIGRATED_PANEL_TYPES="grafana-piechart-panel grafana-singlestat-panel grafana-worldmap-panel graph graphite natel-discrete-panel singlestat table-old"

# What the tests read of a dashboard, in jq. None of it holds an apostrophe, as the shell quotes it.
# shellcheck disable=SC2016 # jq variables and Grafana variables, not the shell's.
DASHBOARDS_JQ='
# The name a reference to a variable names: $name, ${name} or ${name:format}; null for anything else.
def variable: if type == "string" then (capture("^\\$\\{?(?<name>[A-Za-z0-9_]+)(:[a-z]+)?\\}?$") | .name) // null else null end;

# The datasources of Grafana itself, by type, uid or name, the expression datasource among them: they
# need none of the tree.
def own: ["datasource", "grafana", "prometheus-builtin", "__expr__"];

# The names of the datasources of Grafana itself, which a reference gives as its uid: the built-in one, the
# mixed one and the one that reuses the results of another panel, the three that getList in
# public/app/features/plugins/datasource_srv.ts of Grafana v13.1.3 adds to those configured.
def own_names: ["-- Grafana --", "-- Mixed --", "-- Dashboard --"];

# resolves($ref; $datasources; $listed): whether a reference, as Grafana gets it, leads to a datasource:
# a variable that lists the type of one the tree defines, the uid or name of one, or one of its own.
def resolves($ref; $datasources; $listed):
  if $ref == null then true
  elif ($ref | type) == "string" then
    ($ref | IN(own_names[])) or ($ref | IN(own[]))
    or any($datasources[]; .name == $ref or (.uid != "" and .uid == $ref))
    or (($ref | variable) as $name | $name != null and (($listed[$name] // "") | IN($datasources[].type)))
  else
    ($ref.type // null) as $type | ($ref.uid // null) as $uid
    | (($type == null) or ($type | IN($datasources[].type)) or ($type | IN(own[])))
      and ($uid == null or resolves($uid; $datasources; $listed))
  end;

# The variables of type datasource of a dashboard, by name, with the plugin type each lists.
def listed: (.templating.list // []) | map(select(.type == "datasource") | {key: .name, value: (.query | tostring)}) | from_entries;

# Whether the reference of a panel names one datasource, by uid, name or variable, and not the mixed one.
def named: (if type == "string" then . elif type == "object" then (.uid // "") else "" end) as $uid
  | ($uid | type) == "string" and $uid != "" and $uid != "-- Mixed --";

# delivered: the JSON of a dashboard as Grafana gets it: the operator replaces every ${input} of
# spec.datasources with its datasourceName, byte for byte, before it parses the JSON (resolveDatasources in
# controllers/content/resolver.go of grafana-operator v5.25.0), and leaves a reference without the braces.
def delivered: reduce (.datasources[] | select(.inputName and .datasourceName)) as $map
  (.json; split("${\($map.inputName)}") | join($map.datasourceName));

# unresolved($datasources): the references of a dashboard that Grafana reads and that lead nowhere. What
# Grafana 13 reads, at v13.1.3:
#   - not a row, nor the targets a row carries: a row becomes a title, a collapse and a repeat around its
#     panels and runs no query (convertToRowsLayout and buildRowKind in
#     apps/dashboard/pkg/migration/conversion/v1_to_v2alpha1.go);
#   - a panel: it must resolve;
#   - a target, unless its panel names one datasource, by a uid, a name or a variable, that is not the mixed
#     one: Grafana then runs the target against the datasource of the panel, whatever the target names,
#     unless the target is an expression (transformSingleQuery in the same file, which the frontend applies
#     to a dashboard it converts itself in SceneQueryRunner.prepareRequests of @grafana/scenes 8.2.6 and in
#     public/app/features/query/state/PanelQueryRunner.ts);
#   - any other reference, a variable or an annotation among them.
def unresolved($datasources):
  . as $dashboard | listed as $listed
  | [paths | select(.[-1] == "datasource")]
  | map(. as $path
    | ($dashboard | getpath($path)) as $ref
    | ($dashboard | getpath($path[:-1])) as $holder
    | (if ($path | length) >= 5 and $path[-3] == "targets" and $path[-5] == "panels"
       then $dashboard | getpath($path[:-3]) else null end) as $panel
    | if ($path | length) >= 3 and $path[-3] == "panels" and ($holder | type) == "object" and $holder.type == "row" then empty
      elif $panel != null and $panel.type == "row" then empty
      elif $panel != null and ($panel.datasource | named) and resolves($panel.datasource; $datasources; $listed)
        and ($ref | type == "object" and (.uid == "__expr__" or .type == "__expr__") | not) then empty
      elif resolves($ref; $datasources; $listed) then empty
      else $ref end)
  | unique;

# A reference to a variable, as its name in braces, whichever way it is written.
def variable_name: capture("^\\$\\{?(?<name>[A-Za-z_][A-Za-z0-9_]*)") | "${" + .name + "}";

# A string of PromQL, in any of its quotes, from its quote to its own closing one.
def promql_string: "\"(?:[^\"\\\\]|\\\\.)*\"|\u0027(?:[^\u0027\\\\]|\\\\.)*\u0027|`[^`]*`";

# uncommented: a PromQL expression without its comments, each from a # outside a string to the end of its
# line, its strings as they are. Strings and comments are read in one pass from the left, so a quote in a
# comment and a # in a string are taken for what they are.
def uncommented: gsub("(?<string>" + promql_string + ")|#[^\n]*"; .string // " ");

# plain: the same with every string made "".
def plain: uncommented | gsub(promql_string; "\"\"");

# quoted_names: how many of the selectors of a PromQL expression name a metric or a label in quotes, which
# Prometheus 3 admits with any of the quotes and escapes of PromQL: {"a.metric"}, {"job"="x"}, {"j\x6fb"="x"}.
def quoted_names: [plain | scan("\\{[^}]*\\}") | scan("[{,]\\s*\"\"(?=\\s*(?:[,}]|=~|!~|!=|=))")] | length;

# promql: for a PromQL expression, {metrics, unread}: the metric names it selects, and what in it names a
# metric the text does not give: "__name__" for a selector that matches the name by anything but = and a
# literal, "${variable}" for a name a variable completes, and for any variable but those of Grafana, $__...,
# that stands where a metric may: outside strings, ranges, label lists and offsets, and inside the braces of
# a selector too, as a whole matcher, the name of a label or a value without quotes. Grafana puts a whole
# matcher that a variable of one value holds in as it is (interpolateQueryExpr and prometheusRegularEscape in
# dist/esm/escaping.mjs of @grafana/prometheus 13.1.2, which Grafana v13.1.3 pins), so {$m} may be
# {__name__="..."}. A variable that stands for a number is not told from one that stands for a metric. It
# takes out comments and strings, as uncommented and plain read them, ranges and subqueries, label matchers,
# variables, and the label lists of by, without, on, ignoring, group_left and group_right, and reads as a
# metric every identifier left that is no function (one followed by an opening parenthesis) and none of the
# words PromQL keeps, in any case. A metric or a label named in quotes is an error. It does not parse PromQL.
def promql:
  "\\$\\{[^}]*\\}|\\$[A-Za-z_][A-Za-z0-9_]*" as $variable
  | uncommented
  | [scan("__name__\\s*=\\s*\"([A-Za-z_:][A-Za-z0-9_:]*)\"") | .[0]] as $named
  | (if test("__name__\\s*(?:=~|!~|!=)") or test("__name__\\s*=(?![~=])(?!\\s*\"[A-Za-z_:][A-Za-z0-9_:]*\")") then ["__name__"] else [] end) as $by_name
  | if quoted_names > 0 then error("names a metric or a label in quotes, which the check does not read") else . end
  | plain
  | gsub("\\[\\[(?<name>[A-Za-z0-9_]+)(?::[a-z]+)?\\]\\]"; "${" + .name + "}")
  | [scan("(?:" + $variable + ")(?=\\s*[\\[{])")] as $whole
  | [scan("(?<!\\$)\\{(?:\\$\\{[^}]*\\}|[^}])*\\}") | scan($variable) | select(test("\\A\\$\\{?__") | not)] as $matchers
  | gsub("\\[[^\\]]*\\]"; " ")
  | [scan("(?<![A-Za-z0-9_:])(?:[A-Za-z_:][A-Za-z0-9_:]*)?(?:(?:" + $variable + ")[A-Za-z0-9_:]*)+")
      | select(test("\\A(?:" + $variable + ")\\z") | not) | [scan($variable)] | .[0]] as $inside
  | (gsub("(?<![A-Za-z0-9_:])(?:by|without|on|ignoring|group_left|group_right)\\s*\\([^)]*\\)"; " "; "i")
     | gsub("(?<![A-Za-z0-9_:])offset\\s+(?:" + $variable + ")"; " "; "i") | gsub("(?<!\\$)\\{[^}]*\\}"; " ")
     | [scan($variable) | select(test("\\A\\$\\{?__") | not)]) as $standing
  | gsub($variable; "\u00a7")
  | gsub("\\{[^}]*\\}"; " ")
  | gsub("(?<![A-Za-z0-9_:])(?:by|without|on|ignoring|group_left|group_right)\\s*\\([^)]*\\)"; " "; "i")
  | [scan("(?<![A-Za-z0-9_:.\u00a7])[A-Za-z_:][A-Za-z0-9_:]*(?![A-Za-z0-9_:\u00a7]|\\s*\\()")]
  | map(select(ascii_downcase | IN("and", "or", "unless", "bool", "offset", "by", "without", "on", "ignoring", "group_left", "group_right", "atan2", "inf", "nan") | not))
  | {metrics: (. + $named | unique), unread: ($by_name + ($whole + $matchers + $inside + $standing | map(variable_name)) | unique)};

# variable_query: the same for the query of a variable of type query, in the forms the Prometheus datasource
# takes; any other form is an error.
def variable_query:
  gsub("\\A\\s+|\\s+\\z"; "") as $query
  | ($query | gsub("\"(?:[^\"\\\\]|\\\\.)*\""; "\"\"")) as $bare
  | if ($query | test("\\Alabel_names\\(\\s*\\)\\z")) or ($query | test("\\Alabel_values\\(\\s*[A-Za-z_][A-Za-z0-9_]*\\s*\\)\\z"))
    then {metrics: [], unread: []}
    elif ($query | test("\\Alabel_values\\([\\s\\S]+,\\s*[A-Za-z_][A-Za-z0-9_]*\\s*\\)\\z"))
    then ($query | capture("\\Alabel_values\\((?<selector>[\\s\\S]+),\\s*[A-Za-z_][A-Za-z0-9_]*\\s*\\)\\z") | .selector | promql)
    elif ($query | test("\\Aquery_result\\([\\s\\S]+\\)\\z"))
    then ($query | capture("\\Aquery_result\\((?<query>[\\s\\S]+)\\)\\z") | .query | promql)
    elif ($bare | test("\\A(?:[A-Za-z_:][A-Za-z0-9_:]*\\s*(?:\\{[^}]*\\})?|\\{[^}]*\\})\\z"))
    then ($query | promql)
    else error("is none of label_values(<selector>, <label>), query_result(<query>) and a selector") end;

# job_matchers: the matchers on the label job, named bare, of a PromQL expression without its comments,
# each [operator, value], the value as it is written between any of the quotes of PromQL: double, single or
# backticks. A label named in quotes is not read here; quoted_names counts it.
def job_matchers: [uncommented | scan("(?<![A-Za-z0-9_])job\\s*(=~|!~|!=|=)\\s*(?:\"((?:[^\"\\\\]|\\\\.)*)\"|\u0027((?:[^\u0027\\\\]|\\\\.)*)\u0027|`([^`]*)`)")
  | [.[0], (.[1] // .[2] // .[3])]];

# Every panel of a dashboard, those inside its rows included.
def panels: [(.panels // [])[] | ., (select(.type == "row") | (.panels // [])[])] + [(.rows // [])[] | (.panels // [])[]];

# queries($datasources): what a dashboard asks Prometheus: the expr of the targets of every panel and of
# every annotation, and the query of every variable of type query, each with where it is; how many expr
# fields are for another datasource; and how many are where none of these is. A target is for the datasource
# Grafana runs it against: that of its panel where the panel names one, else its own. A reference leads to
# the datasource whose uid or name its uid is, whatever type it gives with it, and to one of its type only
# where it gives no uid (get and getNameOrUid in public/app/features/plugins/datasource_srv.ts of Grafana
# v13.1.3); one the check cannot place is read. It follows the conversion to v2 (transformSingleQuery, as
# unresolved does), which Grafana v13.1.3 makes of every dashboard while the toggle dashboardNewLayouts is on,
# as it is by default and as the Grafana of this tree leaves it (pkg/services/featuremgmt/registry.go, and
# getDashboardsApiVersion in public/app/features/dashboard/api/utils.ts). With the toggle off, a panel whose
# reference gives a type alone is run on another path, which this does not follow, so turning it off means
# reading this again.
def queries($datasources):
  listed as $listed
  | def prometheus:
      def type_of: if . == null then null
        elif type == "object" then (if (.uid // "") != "" then .uid | type_of elif (.type // "") != "" then .type else null end)
        elif type == "string" then
          (variable as $name | if $name != null and ($listed | has($name)) then $listed[$name] else null end)
          // ([. as $ref | $datasources[] | select(.name == $ref or (.uid != "" and .uid == $ref)) | .type] | first)
        else null end;
      type_of as $type | $type == null or $type == "prometheus";
    ([panels[] | select(.type != "row") | . as $panel | (.targets // [])[] | select(has("expr"))
        | {where: "panel \($panel.id // "?")", text: .expr,
           read: ((if ($panel.datasource | named) then $panel.datasource else (.datasource // $panel.datasource) end) | prometheus)}]
      + [(.annotations.list // [])[] | select(has("expr")) | {where: "annotation \(.name // "?")", text: .expr, read: (.datasource | prometheus)}]) as $exprs
  | ([panels[] | select(.type == "row") | (.targets // [])[] | select(has("expr"))] | length) as $in_rows
  | {exprs: [$exprs[] | select(.read and (.text | type) == "string") | {where, text}],
     other: ([$exprs[] | select(.read | not)] | length),
     elsewhere: (([.. | objects | select(has("expr"))] | length) - ($exprs | length) - $in_rows),
     variables: [(.templating.list // [])[] | select(.type == "query") | select(.datasource | prometheus)
       | {where: "variable \(.name)", text: (.query | if type == "object" then .query else . end)}]};

# The variables of a dashboard that hold one fixed text, a constant or a text box with a default, by name.
def constants: (.templating.list // []) | map(select(.type == "constant" or .type == "textbox")
  | {key: .name, value: ((.current.value // .query // "") | tostring)} | select(.value != "")) | from_entries;

# The text with each such variable replaced by what it holds.
def substituted($constants): reduce ($constants | to_entries[]) as $c (.;
  gsub("\\$\\{" + $c.key + "(?::[a-z]+)?\\}|\\[\\[" + $c.key + "(?::[a-z]+)?\\]\\]|\\$" + $c.key + "(?![A-Za-z0-9_])"; $c.value));

# rows: the rows of the table of metric sources, from its text.
def rows: split("\n") | to_entries
  | map(select(.value != "" and (.value | startswith("#") | not)) | (.value | split("\t")) as $cells
    | {line: (.key + 1), dashboard: $cells[0], pattern: ($cells[1] // ""), source: ($cells[2] // ""), note: ($cells[3] // ""), cells: ($cells | length)});

# scraped: what is wrong with what one dashboard asks Prometheus, and what is known of it. $board is
# {name, model}; $rows the rows of the table; $monitors [{id, drops, keeps}]; $records and $alerts names;
# $strict whether the dashboard is one written for this tree. A monitor drops a metric that one of its drops
# matches whole, or that one of its keeps does not.
def scraped($board; $rows; $monitors; $records; $alerts; $datasources; $strict):
  $board.name as $name
  | ($board.model | constants) as $constants
  | ($board.model | queries($datasources)) as $queries
  | [($queries.exprs[] | . + {parsed: (. as $q | try ($q.text | substituted($constants) | promql) catch {error: .})}),
     ($queries.variables[] | . + {parsed: (. as $q | try (if ($q.text | type) == "string" then $q.text | substituted($constants) | variable_query else error("holds no query") end) catch {error: .})})] as $parsed
  | [$rows[] | select(.dashboard == $name)] as $mine
  | [$mine[] | select(.source | startswith("unread:"))] as $unread_rows
  | [$mine[] | select(.source | startswith("unread:") | not)] as $metric_rows
  | ([$parsed[] | .parsed.metrics // [] | .[]] | unique) as $metrics
  | ([$parsed[] | .parsed.unread // [] | .[]] | group_by(.) | map({kind: .[0], count: length})) as $unread
  # Each metric with the row that names it: the first of the rows of the dashboard whose pattern is the whole name.
  | [$metrics[] | . as $metric
      | {metric: $metric, recorded: ($records | index($metric) != null),
         row: ([$metric_rows[] | select(.pattern as $pattern | try ($metric | test("\\A(?:" + $pattern + ")\\z")) catch false)] | first)}] as $matched
  | {name: $name,
     problems: (
       [$parsed[] | select(.parsed.error) | "\($name): \(.where): \(.parsed.error)"]
       # promql takes a variable named $__... for one of Grafana itself, and does not read it where it stands
       # for a name, so a dashboard may define none of that name.
       + [($board.model.templating.list // [])[] | .name | strings | select(startswith("__"))
           | "\($name): variable \(.): the check takes $__... for Grafana\u0027s own and does not read it"]
       + (if $queries.elsewhere != 0 then ["\($name): \($queries.elsewhere) expr fields are where the check does not read"] else [] end)
       + [$matched[] | select(.recorded | not)
           | if .row == null then "\($name): \(.metric): no row of the table names it, and no rule records it"
             elif .row.source == "none" then empty
             elif .row.source == "any-monitor" then (if ($monitors | length) > 0 then empty else "\($name): \(.metric): the render has no monitor" end)
             elif .row.source == "alerting-rule" then (if ($alerts | length) > 0 then empty else "\($name): \(.metric): the render has no alerting rule" end)
             else .metric as $metric | .row.source as $source
               | [$source | split(",")[] as $id | $monitors[] | select(.id == $id)] as $present
               | if ($present | length) == 0 then "\($name): \($metric): \($source) is not in the render"
                 elif all($present[]; any(.drops[]; . as $drop | try ($metric | test("\\A(?:" + $drop + ")\\z")) catch false)
                     or any((.keeps // [])[]; . as $keep | try ($metric | test("\\A(?:" + $keep + ")\\z") | not) catch false))
                 then "\($name): \($metric): \($present | map(.id) | join(",")) drops it, by a metricRelabelings rule on __name__"
                 else empty end
             end]
       + [$unread[] | . as $u | ([$unread_rows[] | select(.pattern == $u.kind)] | first) as $row
           | if $strict then "\($name): \($u.count) expressions name a metric by \($u.kind), which a dashboard written for this tree may not"
             elif $row == null then "\($name): \($u.count) expressions name a metric by \($u.kind), which the check does not read: the table pins no unread:\($u.count) for \($u.kind)"
             elif $row.source != "unread:\($u.count)" then "\($name): \($u.count) expressions name a metric by \($u.kind), and the table pins \($row.source)"
             else empty end]
       + [$unread_rows[] | select(.pattern as $kind | any($unread[]; .kind == $kind) | not) | "\($name): line \(.line): no expression names a metric by \(.pattern)"]
       + [$metric_rows[] | select(.line as $line | any($matched[]; (.recorded | not) and .row != null and .row.line == $line) | not)
           | "\($name): line \(.line): \(.pattern) matches nothing the dashboard reads"]
       + (if $strict then [$mine[] | select(.source == "none" or (.source | startswith("unread:")) or (.pattern | test("\\A[A-Za-z_:][A-Za-z0-9_:]*\\z") | not))
           | "\($name): line \(.line): a dashboard written for this tree names each metric literally, with the monitor that scrapes it"] else [] end)),
     known: [$matched[] | "\($name): \(.metric): " + (if .recorded then "recorded by a rule" elif .row == null then "unknown" else .row.source end)],
     read: {expressions: ($queries.exprs | length), variables: ($queries.variables | length), other: $queries.other,
            metrics: ($metrics | length), unread: $unread}};

# table_problems($rows; $names): what is wrong with the table itself.
def table_problems($rows; $names):
  [$rows[]
    | if .cells < 3 or .cells > 4 or .dashboard == "" or .pattern == "" or .source == "" then "line \(.line): a row is a dashboard, a pattern, a source and, for some, a reason, separated by tabs"
      elif (.dashboard as $d | $names | index($d)) == null then "line \(.line): \(.dashboard) is no dashboard the tree keeps"
      elif (.source | test("\\A(?:none|any-monitor|alerting-rule|unread:[1-9][0-9]*|(?:ServiceMonitor|PodMonitor)/[a-z0-9.-]+(?:,(?:ServiceMonitor|PodMonitor)/[a-z0-9.-]+)*)\\z") | not) then "line \(.line): \(.source) is no source"
      elif (.source == "none" or (.source | startswith("unread:"))) and .note == "" then "line \(.line): \(.source) needs its reason in a fourth column"
      else empty end];
'

setup_file() {
  # Helm's cache and registry settings stay in the run's own directory, and so does the Docker
  # configuration helm falls back to for credentials, so no login is read.
  export HELM_CACHE_HOME="$BATS_FILE_TMPDIR/helm/cache"
  export HELM_CONFIG_HOME="$BATS_FILE_TMPDIR/helm/config"
  export HELM_DATA_HOME="$BATS_FILE_TMPDIR/helm/data"
  export DOCKER_CONFIG="$BATS_FILE_TMPDIR/docker"
  mkdir -p "$DOCKER_CONFIG"
  # Nor does git read the user's or the system's configuration, credential helpers included.
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
  # flux build rewrites the kustomization.yaml of what it builds and puts it back afterwards, so it
  # builds a copy of the applications, never this checkout. The cluster directories stay behind.
  export TREE="$BATS_FILE_TMPDIR/tree"
  mkdir -p "$TREE/kubernetes"
  cp -R "$BATS_TEST_DIRNAME/../kubernetes/apps" "$BATS_TEST_DIRNAME/../kubernetes/components" "$TREE/kubernetes/"
}

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CLUSTER="$REPO/kubernetes/clusters/lab-sto2"
  KUBE="$(yq -e '.kubernetes' "$REPO/versions.yaml")"
  NAMESPACE=monitoring
  TABLE="$BATS_TEST_DIRNAME/fixtures/dashboards/metric-sources.tsv"
  # Nothing to connect to: a step that needed a cluster fails instead of finding one.
  export KUBECONFIG="$BATS_TEST_TMPDIR/no-kubeconfig"
  unset KUBERNETES_SERVICE_HOST KUBERNETES_SERVICE_PORT
}

# app_dir APP: sets APP_DIR to the directory of the application APP, in whichever namespace
# directory it is, relative to the repository.
app_dir() {
  local -a dirs=("$TREE"/kubernetes/apps/base/*/"$1")
  [ -f "${dirs[0]}/ks.yaml" ] || { echo "$1: no application directory with a ks.yaml"; return 1; }
  APP_DIR="${dirs[0]#"$TREE"/}"
}

# built APP: the application APP as Flux applies it: its app/ built with its ks.yaml, substituting
# strictly the variables of the cluster's example key lists, once per run. Sets BUILT, the file that
# holds it, and APP_DIR.
built() {
  local app=$1 vars="$BATS_FILE_TMPDIR/example-vars.yaml" ks="$BATS_FILE_TMPDIR/built/$1-ks.yaml"
  app_dir "$app"
  BUILT="$BATS_FILE_TMPDIR/built/$app.yaml"
  if [ ! -s "$BUILT" ]; then
    mkdir -p "$BATS_FILE_TMPDIR/built"
    # shellcheck disable=SC2016 # $list is a yq variable.
    yq ea '. as $list ireduce ({}; . * ($list // {}))' \
      "$CLUSTER/cluster-config.example.yaml" "$CLUSTER/cluster-secrets.example.yaml" >"$vars"
    # shellcheck disable=SC2016 # $vars is a yq variable.
    yq ea 'select(fileIndex == 0) as $vars | select(fileIndex == 1 and . != null)
      | .spec.postBuild.substitute = $vars' "$vars" "$TREE/$APP_DIR/ks.yaml" >"$ks"
    # Built from the tree's parent, with paths from there, as scripts/kubernetes-check builds.
    (cd "$TREE" && flux build kustomization "$app" --path "./$APP_DIR/app" \
      --kustomization-file "$ks" --dry-run --strict-substitute) >"$BUILT.partial"
    mv "$BUILT.partial" "$BUILT"
  fi
}

# chart APP: pulls the chart the application APP's OCIRepository names, at its pinned tag, once per
# run. Sets CHART, the archive, CHART_TAG, the tag, and CHART_APP_VERSION, the appVersion the chart
# declares, besides what built() sets.
chart() {
  local url pulled
  built "$1"
  url="$(yq -N 'select(.kind == "OCIRepository") | .spec.url' "$BUILT")"
  CHART_TAG="$(yq -N 'select(.kind == "OCIRepository") | .spec.ref.tag' "$BUILT")"
  pulled="$BATS_FILE_TMPDIR/charts/${url##*/}/$CHART_TAG"
  if [ ! -d "$pulled" ]; then
    mkdir -p "$pulled"
    helm pull "$url" --version "$CHART_TAG" --destination "$pulled"
  fi
  CHART="$(echo "$pulled"/*.tgz)"
  # The chart's own Chart.yaml, not that of a chart it carries.
  CHART_APP_VERSION="$(tar -xzOf "$CHART" "$(tar -tzf "$CHART" | grep -m1 -E '^[^/]+/Chart\.yaml$')" | yq '.appVersion')"
}

# render APP: the chart that APP's HelmRelease installs, rendered as helm-controller renders it with
# the values of the ConfigMap it reads and its own over them, as grafana.bats renders it, once per
# run. Sets RENDERED, the file that holds it, besides what chart() sets.
render() {
  local app=$1 name release namespace values inline
  chart "$app"
  RENDERED="$BATS_FILE_TMPDIR/rendered/$app.yaml"
  if [ ! -s "$RENDERED" ]; then
    mkdir -p "$BATS_FILE_TMPDIR/rendered"
    name="$(yq -N 'select(.kind == "HelmRelease") | .spec.valuesFrom[0].name' "$BUILT")"
    release="$(yq -N 'select(.kind == "HelmRelease") | .spec.releaseName // .metadata.name' "$BUILT")"
    namespace="$(yq -N 'select(.kind == "HelmRelease") | .spec.targetNamespace // .metadata.namespace' "$BUILT")"
    values="$BATS_FILE_TMPDIR/rendered/$app-values.yaml"
    yq -N "select(.kind == \"ConfigMap\" and .metadata.name == \"$name\") | .data[\"values.yaml\"]" "$BUILT" >"$values"
    [ -s "$values" ] || { echo "$app: no values in the ConfigMap $name its HelmRelease reads"; return 1; }
    inline="$BATS_FILE_TMPDIR/rendered/$app-inline.yaml"
    yq -N 'select(.kind == "HelmRelease") | .spec.values // {}' "$BUILT" >"$inline"
    helm template "$release" "$CHART" --namespace "$namespace" --kube-version "$KUBE" --include-crds \
      --api-versions monitoring.coreos.com/v1 --api-versions monitoring.coreos.com/v1alpha1 \
      --api-versions monitoring.coreos.com/v1/ServiceMonitor --api-versions monitoring.coreos.com/v1/PodMonitor \
      --api-versions grafana.integreatly.org/v1beta1 --api-versions grafana.integreatly.org/v1beta1/GrafanaDashboard \
      --api-versions grafana.integreatly.org/v1beta1/GrafanaDatasource \
      --values "$values" --values "$inline" >"$RENDERED.partial"
    mv "$RENDERED.partial" "$RENDERED"
  fi
}

# cluster_render: what the cluster's overlay renders, with every chart expanded, by scripts/render,
# once per run. Sets CLUSTER_RENDER to the cluster's directory in it.
cluster_render() {
  local out="$BATS_FILE_TMPDIR/cluster-render"
  if [ ! -d "$out/lab-sto2" ]; then
    rm -rf "$out"
    "$REPO/scripts/render" "$out" "$REPO" >"$BATS_FILE_TMPDIR/cluster-render.log" 2>&1 ||
      { cat "$BATS_FILE_TMPDIR/cluster-render.log"; return 1; }
  fi
  CLUSTER_RENDER="$out/lab-sto2"
}

# grafana_labels: the labels of the one Grafana in $BUILT, as a JSON object on one line.
grafana_labels() {
  yq -N -o json -I0 'select(.kind == "Grafana") | .metadata.labels // {}' "$BUILT"
}

# dashboard_apps: the applications of the tree that hold a GrafanaDashboard of their own, sorted,
# on one line.
dashboard_apps() {
  local file
  for file in "$TREE"/kubernetes/apps/base/*/*/app/grafanadashboard*.yaml; do
    basename "$(dirname "$(dirname "$file")")"
  done | sort -u | paste -sd' ' -
}

# pinned_apps: fails, naming both, unless the applications that deliver a dashboard are the pinned
# ones.
pinned_apps() {
  local apps
  apps="$(dashboard_apps)"
  echo "applications that deliver a dashboard: $apps"
  [ "$apps" = "$DASHBOARD_APPS" ] || { echo "the tests pin: $DASHBOARD_APPS"; return 1; }
}

# pinned_by APP: the application whose pinned chart releases what the application APP describes:
# APP itself, but for the two applications of monitors alone, whose targets the chart of another
# application runs.
pinned_by() {
  case $1 in
    cilium-monitoring) echo cilium ;;
    linstor-monitoring) echo piraeus-operator ;;
    *) echo "$1" ;;
  esac
}

# boards FILE...: one JSON object per line for each GrafanaDashboard in the files: its name, its
# folder, the datasources it maps, and its dashboard's JSON as a string, from the ConfigMap it names
# or from its spec.json. A dashboard that loads from anywhere else has null for json.
boards() {
  yq -N -o json -I0 'select(. != null)' "$@" | jq -c -s '. as $all | .[] | select(.kind == "GrafanaDashboard") | . as $board
    | {name: .metadata.name, folder: (.spec.folder // null), datasources: (.spec.datasources // []),
       json: (if .spec.json then .spec.json
         elif .spec.configMapRef then ([$all[] | select(.kind == "ConfigMap" and .metadata.name == $board.spec.configMapRef.name)
           | .data[$board.spec.configMapRef.key]] | first)
         else null end)}'
}

# all_boards: every dashboard of the tree, once per run, one JSON object per line in $BOARDS, as
# boards() gives them with their application: those of the applications that hold a GrafanaDashboard,
# and those of the monitoring chart, which the release of the grafana application renders and which
# have null for their application.
all_boards() {
  local app
  BOARDS="$BATS_FILE_TMPDIR/boards.jsonl"
  if [ ! -s "$BOARDS" ]; then
    for app in $(dashboard_apps); do
      built "$app"
      boards "$BUILT" | jq -c --arg app "$app" '. + {app: $app}'
    done >"$BOARDS.partial"
    # The pull's messages go to the test's output, not into what a caller captures.
    render grafana >&2
    boards "$RENDERED" | jq -c '. + {app: null}' >>"$BOARDS.partial"
    mv "$BOARDS.partial" "$BOARDS"
  fi
}

# datasources: the datasources of the Grafana, as built, once per run: sets DATASOURCES to a JSON
# array of each one's name, type and uid.
datasources() {
  built grafana
  DATASOURCES="$(yq -N -o json -I0 'select(.kind == "GrafanaDatasource")' "$BUILT" |
    jq -s -c '[.[] | {name: .spec.datasource.name, type: .spec.datasource.type, uid: (.spec.uid // "")}]')"
}

# kept: the dashboards the tree keeps as JSON, those an application delivers, once per run, one
# JSON object per line in $KEPT: its name, application and folder, and its JSON, parsed, as Grafana
# gets it.
kept() {
  all_boards
  KEPT="$BATS_FILE_TMPDIR/kept.jsonl"
  if [ ! -s "$KEPT" ]; then
    jq -c "$DASHBOARDS_JQ"'select(.app != null) | {name, app, folder, model: (delivered | fromjson)}' "$BOARDS" >"$KEPT.partial"
    mv "$KEPT.partial" "$KEPT"
  fi
}

# unaccounted_dashboards RENDER...: the names of the GrafanaDashboards in the rendered files that
# neither an application that holds a grafanadashboard*.yaml nor the monitoring chart's release
# delivers, sorted. A dashboard in a file of any other name is checked by nothing else.
unaccounted_dashboards() {
  local known="$BATS_TEST_TMPDIR/known-dashboards.txt"
  all_boards >&2
  jq -r .name "$BOARDS" | sort -u >"$known"
  yq -N 'select(. != null) | select(.kind == "GrafanaDashboard") | .metadata.name' "$@" | sort -u | comm -23 - "$known"
}

# configmap_value FILE NAME KEY: the value of KEY in the ConfigMap NAME of FILE, as bytes, with
# nothing added.
configmap_value() {
  MAP=$2 KEY=$3 yq -N -o json -I0 'select(.kind == "ConfigMap" and .metadata.name == strenv(MAP)) | .data[strenv(KEY)]' "$1" | jq -j .
}

# board_file APP BOARD: the file of the application APP, relative to the repository, that defines
# the GrafanaDashboard BOARD.
board_file() {
  local file
  app_dir "$1"
  for file in "$TREE/$APP_DIR"/app/grafanadashboard*.yaml; do
    if [ "$(yq -N 'select(.kind == "GrafanaDashboard") | .metadata.name' "$file")" = "$2" ]; then
      echo "${file#"$TREE"/}"
      return 0
    fi
  done
  echo "$2: no grafanadashboard*.yaml of $1 defines it" >&2
  return 1
}

# record FILE KEY: the values the comment lines "# KEY: value" of FILE give, one per line.
record() {
  grep -E "^[[:blank:]]*#[[:blank:]]*$2:[[:blank:]]*[^[:blank:]]+[[:blank:]]*\$" "$REPO/$1" | sed -E 's/^[^:]*:[[:blank:]]*//; s/[[:blank:]]*$//'
}

# held_at CHART PATH: the chart directory of the archive CHART that holds the file PATH, a path
# inside the chart: the nearest directory above the file with a Chart.yaml, the chart's own or that
# of a chart it carries under charts/. Sets HELD_BY to that Chart.yaml, as a path inside the chart,
# and HELD_AT to the version it declares.
held_at() {
  local root holder
  root="$(tar -tzf "$1" | head -1 | cut -d/ -f1)"
  holder="$(dirname "$root/$2")"
  until tar -tzf "$1" | grep -qxF "$holder/Chart.yaml"; do
    [ "$holder" != "$root" ] || { echo "no Chart.yaml above $2 in the chart"; return 1; }
    holder="$(dirname "$holder")"
  done
  HELD_BY="${holder#"$root"}/Chart.yaml"
  HELD_BY="${HELD_BY#/}"
  HELD_AT="$(tar -xzOf "$1" "$holder/Chart.yaml" | yq '.version')"
}

# overlay_names OVERLAY_KUSTOMIZATION_DIR: the names of the Kustomizations the overlay in the
# directory builds, sorted, on one line.
overlay_names() {
  kustomize build --load-restrictor LoadRestrictionsNone "$1" |
    yq -N 'select(.kind == "Kustomization") | .metadata.name' | sort | paste -sd' ' -
}

# without DIR NAME...: a copy of the kubernetes/ directory of this repository in DIR, whose overlay
# no longer lists the ks.yaml of the applications NAME... Sets WITHOUT to the overlay's directory.
without() {
  local dir=$1 name
  shift
  rm -rf "$dir"
  mkdir -p "$dir"
  cp -R "$REPO/kubernetes" "$dir/"
  WITHOUT="$dir/kubernetes/apps/overlays/lab-sto2"
  for name in "$@"; do
    # The line of the application's ks.yaml, in whichever namespace directory it is.
    sed -i -E "\#^[[:blank:]]*-[[:blank:]]+\.\./\.\./base/[^/]+/$name/ks\.yaml#d" "$WITHOUT/kustomization.yaml"
  done
}

# The ceiling of what a ConfigMap holds: the sum of its data and binaryData values, as the API
# server counts, is at most 1 MiB. A GrafanaDashboard that carries its JSON is held to the same.
CONFIGMAP_LIMIT=1048576

# oversized FILE...: names, one per line, each ConfigMap in the files whose data holds more than a
# ConfigMap can, and each GrafanaDashboard whose JSON is more than that; the status is non-zero when
# there is one.
oversized() {
  local found
  found="$(yq -N -o json -I0 'select(. != null)' "$@" | jq -r --argjson limit "$CONFIGMAP_LIMIT" '
    select(.kind == "ConfigMap" or .kind == "GrafanaDashboard")
    | (if .kind == "ConfigMap" then [(.data // {} | .[] | utf8bytelength), (.binaryData // {} | .[] | length)]
       else [(.spec.json // "" | utf8bytelength)] end | add // 0) as $size
    | select($size > $limit) | "\(.kind)/\(.metadata.name) holds \($size) bytes, over the \($limit) a ConfigMap holds"')"
  if [ -n "$found" ]; then
    echo "$found"
    return 1
  fi
}

# metrics: the metric names the PromQL expression on its input selects, one per line, then one line
# "unread: WHAT" for each thing in it that names a metric the text does not give (promql in
# DASHBOARDS_JQ); fails on an expression the check does not read at all.
metrics() {
  jq -R -s -r "$DASHBOARDS_JQ"'promql | .metrics[], (.unread[] | "unread: " + .)'
}

# variable_metrics: the same for the query of a variable; fails on a form the check does not know.
variable_metrics() {
  jq -R -s -r "$DASHBOARDS_JQ"'variable_query | .metrics[], (.unread[] | "unread: " + .)'
}

# unresolved: the datasource references of the dashboard on its input, as Grafana gets it, that
# Grafana reads and that lead to no datasource, one per line (unresolved in DASHBOARDS_JQ). Needs
# DATASOURCES.
unresolved() {
  jq -c --argjson datasources "$DATASOURCES" "$DASHBOARDS_JQ"'unresolved($datasources)[]'
}

# queried: for the dashboard on its input, how many expressions of its targets and annotations the
# check reads as Prometheus' and how many it leaves to another datasource, as "READ OTHER" (queries in
# DASHBOARDS_JQ). Needs DATASOURCES.
queried() {
  jq -r --argjson datasources "$DATASOURCES" "$DASHBOARDS_JQ"'queries($datasources) | "\(.exprs | length) \(.other)"'
}

# relabeled FILE...: the monitors in the files, as a JSON array of each one's id, Kind/name, and of
# the regular expressions of the metricRelabelings rules on __name__ alone of its endpoints: drops,
# those of action drop, and keeps, those of action keep, the action in either case, as the monitors'
# definition admits both. A rule that gives no regex has Prometheus' default, (.*).
relabeled() {
  yq -N -o json -I0 'select(. != null)' "$@" |
    jq -s -c 'map([(.spec.endpoints // .spec.podMetricsEndpoints // [])[] | (.metricRelabelings // [])[]
        | select(.sourceLabels == ["__name__"]) | {action: (.action // "replace" | ascii_downcase), regex: (.regex // "(.*)")}] as $rules
      | {id: (.kind + "/" + .metadata.name),
         drops: [$rules[] | select(.action == "drop") | .regex], keeps: [$rules[] | select(.action == "keep") | .regex]})'
}

# scrape: what the cluster's render scrapes and records, once per run: sets MONITORS to a file of
# the monitors as relabeled gives them, and RULES to a file of the names the rules of the render
# record and of its alerts.
scrape() {
  cluster_render
  MONITORS="$BATS_FILE_TMPDIR/monitors.json"
  RULES="$BATS_FILE_TMPDIR/rules.json"
  if [ ! -s "$RULES" ]; then
    relabeled "$CLUSTER_RENDER"/*/ServiceMonitor.monitoring.coreos.com_*.yaml \
      "$CLUSTER_RENDER"/*/PodMonitor.monitoring.coreos.com_*.yaml >"$MONITORS"
    yq -N -o json -I0 'select(. != null) | .spec.groups[].rules[]' "$CLUSTER_RENDER"/*/PrometheusRule.monitoring.coreos.com_*.yaml |
      jq -s -c '{records: (map(select(.record) | .record) | unique), alerts: (map(select(.alert) | .alert) | unique)}' >"$RULES.partial"
    mv "$RULES.partial" "$RULES"
  fi
}

# scraped KEPT TABLE MONITORS RULES [NAME...]: checks what the dashboards of the file KEPT ask
# Prometheus against the table TABLE and the files MONITORS and RULES of scrape (scraped in
# DASHBOARDS_JQ); with NAMEs, those dashboards and their rows alone. Prints "problem: ..." for each
# thing wrong, "known: ..." for each metric with where it comes from, and "read: ..." for what was
# read of each dashboard. Needs DATASOURCES.
scraped() {
  local kept=$1 table=$2 monitors=$3 rules=$4
  shift 4
  # shellcheck disable=SC2016 # jq variables.
  jq -s -r --rawfile table "$table" --slurpfile monitors "$monitors" --slurpfile rules "$rules" \
    --argjson datasources "$DATASOURCES" --arg strict "$OWN_DASHBOARDS cluster-home" --arg only "$*" "$DASHBOARDS_JQ"'
    ($only | split(" ") | map(select(. != ""))) as $only
    | ($strict | split(" ")) as $strict
    | [.[] | select(($only | length) == 0 or (.name as $name | $only | index($name) != null))] as $boards
    | ($table | rows | map(select(($only | length) == 0 or (.dashboard as $name | $only | index($name) != null)))) as $rows
    | [$boards[] | . as $board
        | scraped($board; $rows; $monitors[0]; $rules[0].records; $rules[0].alerts; $datasources; ($strict | index($board.name) != null))] as $results
    | (table_problems($rows; [$boards[].name])[] | "problem: the table: " + .),
      ($results[] | .problems[] | "problem: " + .),
      ($results[] | .known[] | "known: " + .),
      ($results[] | "read: \(.name): \(.read | tojson)")' "$kept"
}

# jobs: the job labels the monitors of the cluster's render give their series, as a JSON array: the
# replacement a relabeling of the monitor writes to job; else, for a PodMonitor without a jobLabel,
# its namespace and name; else, for a ServiceMonitor, the value of its jobLabel on each Service of
# the render it selects, or that Service's name (generatePodMonitorConfig and
# generateServiceMonitorConfig in pkg/prometheus/promcfg.go of prometheus-operator v0.95.2). An
# object the render holds without a namespace is in the namespace its application deploys into. A
# PodMonitor with a jobLabel, whose pods the render does not hold, and a ServiceMonitor whose Service
# the render does not hold give no job here.
jobs() {
  cluster_render
  # shellcheck disable=SC2016 # jq variables.
  yq -N -o json -I0 'select(. != null) | {"file": filename, "object": .}' \
    "$CLUSTER_RENDER"/*/ServiceMonitor.monitoring.coreos.com_*.yaml "$CLUSTER_RENDER"/*/PodMonitor.monitoring.coreos.com_*.yaml \
    "$CLUSTER_RENDER"/*/Service_*.yaml "$CLUSTER_RENDER"/*/Kustomization.kustomize.toolkit.fluxcd.io_*.yaml |
    jq -s -c '
      map(. + {app: (.file | split("/") | .[-2])}) as $all
      | ([$all[] | select(.object.kind == "Kustomization") | {key: .object.metadata.name, value: (.object.spec.targetNamespace // "")}] | from_entries) as $targets
      | def namespace: .object.metadata.namespace // $targets[.app] // "";
        [$all[] | select(.object.kind == "Service")] as $services
      | [$all[] | select(.object.kind == "ServiceMonitor" or .object.kind == "PodMonitor") | . as $monitor | .object as $o
          | ($monitor | namespace) as $namespace
          | ($o.spec.endpoints // $o.spec.podMetricsEndpoints // [])[]
          | ([(.relabelings // [])[] | select(.targetLabel == "job" and (.action // "replace") == "replace"
                and ((.sourceLabels // []) | length) == 0 and (.replacement // "") != "") | .replacement] | last) as $written
          | if $written != null then $written
            elif $o.kind == "PodMonitor" then (if ($o.spec.jobLabel // "") == "" then "\($namespace)/\($o.metadata.name)" else empty end)
            else
              ($o.spec.selector.matchLabels // {}) as $labels | ($o.spec.selector.matchExpressions // []) as $expressions
              | (if $o.spec.namespaceSelector.any == true then null else ($o.spec.namespaceSelector.matchNames // [$namespace]) end) as $namespaces
              | $services[] | . as $service | ($service.object.metadata.labels // {}) as $has
              | select($namespaces == null or (($service | namespace) as $in | $namespaces | index($in) != null))
              | select((($labels | length) + ($expressions | length)) > 0
                  and ($labels | to_entries | all(.value == $has[.key]))
                  and ($expressions | all(. as $e | $has[$e.key] as $value
                    | if $e.operator == "In" then $value != null and ($e.values | index($value) != null)
                      elif $e.operator == "NotIn" then $value == null or ($e.values | index($value) == null)
                      elif $e.operator == "Exists" then $value != null
                      elif $e.operator == "DoesNotExist" then $value == null
                      else false end)))
              | $has[$o.spec.jobLabel // ""] // $service.object.metadata.name
            end]
      | unique'
}

# own_problems KEPT JOBS: what is wrong with the dashboards written for this tree among those of the
# file KEPT, one per line, each with the dashboard's name, given JOBS, the JSON array of the jobs the
# monitors of the render give.
own_problems() {
  # shellcheck disable=SC2016 # jq variables.
  jq -r --arg own "$OWN_DASHBOARDS" --argjson jobs "$2" "$DASHBOARDS_JQ"'
    select(.name as $name | $own | split(" ") | index($name) != null)
    | .name as $name | .model as $model
    | ([($model.templating.list // [])[] | select(.type == "datasource")]) as $sources
    | {"type": "prometheus", "uid": "${\($sources[0].name // "")}"} as $reference
    | (if $model.uid != $name then "its uid is \($model.uid), not its name" else empty end),
      (if ($model.title // "") == "" then "no title" else empty end),
      (if $model.editable != false then "it is editable" else empty end),
      # One variable of type datasource, for Prometheus, as the home has, which every panel and target names.
      (if ($sources | length) != 1 or $sources[0].query != "prometheus" then "it has not one variable of type datasource for prometheus" else empty end),
      # And no other: Grafana puts the text of any other variable in a query with no more escaped than its
      # backslashes and apostrophes, or, for a variable of several values, its backslashes and the characters of a
      # regular expression, and adds an ad hoc filter to every query of its datasource (interpolateQueryExpr and
      # enhanceExprWithAdHocFilters of @grafana/prometheus 13.1.2), so either may select by a name or a job that
      # the checks do not read.
      (($model.templating.list // [])[] | select(.type != "datasource")
        | "it defines the variable \(.name // "?"), of type \(.type // "none"), and may define none but its datasource"),
      ($model | panels[] | select(.type != "row") | select(.datasource != $reference) | "panel \(.id // "?") reads \(.datasource | tojson), not the variable"),
      ($model | panels[] | select(.type != "row") | . as $panel | (.targets // [])[] | select(.datasource != $reference) | "a target of panel \($panel.id // "?") reads \(.datasource | tojson), not the variable"),
      (if ($model | has("__inputs")) then "it declares inputs" else empty end),
      (($model | panels | length) as $count | if $count > 10 or $count < 1 then "it has \($count) panels" else empty end),
      # No address, hostname or identifier, in any text of it or key.
      ($model | [paths as $path | ($path[] | strings), (getpath($path) | strings)] | unique[]
        | select(test("(?<![0-9.])[0-9]{1,3}(\\.[0-9]{1,3}){3}(?![0-9.])") or test("(?<![0-9A-Fa-f:])[0-9A-Fa-f]{1,4}(:[0-9A-Fa-f]{0,4}){3,}")
            or test("[A-Za-z0-9_-]\\.[A-Za-z]") or test("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}") or test("[0-9a-fA-F]{32}"))
        | "it holds what reads as an address, a hostname or an identifier: \(.)"),
      # A job is matched by = and a literal, and the literal is a job a monitor of the render gives. Every label
      # is named bare: one in quotes may be job, and the check of jobs does not read it.
      ($model | queries([]) | (.exprs[], .variables[]) | .where as $where | .text | strings
        | if quoted_names > 0 then "\($where) names a metric or a label in quotes, which a dashboard written for this tree may not"
          else job_matchers[]
            | if .[0] != "=" or (.[1] | test("\\$")) then "\($where) matches job by \(.[0]) \(.[1]), not by = and a literal"
              elif (.[1] as $job | $jobs | index($job)) == null then "\($where) matches the job \(.[1]), which no monitor of the render gives"
              else empty end
          end)
    | "\($name): " + .' "$1"
}

# home_problems KEPT: what is wrong with the home dashboard among those of the file KEPT, one per
# line, with its name.
home_problems() {
  jq -r 'select(.name == "cluster-home" and .app == "grafana")
    | .name as $name
    | (.model.templating.list // [])[] | select(.type != "datasource")
    | "\($name): it defines the variable \(.name // "?"), of type \(.type // "none"), and may define none but its datasource"' "$1"
}

# doc_table HEADER: the rows of the table of docs/kubernetes.md whose header line is HEADER, one
# per line, without the line under the header.
doc_table() {
  awk -v header="$1" '$0 == header { table = 1; next } table && !/^\|/ { exit } table && !/^\| *-/ { print }' "$REPO/docs/kubernetes.md"
}

# cell N: the Nth cell of the table row on its input, without the blanks around it.
cell() {
  awk -F'|' -v n="$1" '{ value = $(n + 1); gsub(/^[ \t]+|[ \t]+$/, "", value); print value }'
}

# backticked: what its input holds in backticks, one per line.
backticked() {
  # shellcheck disable=SC2016 # The backticks are Markdown's, not a command.
  grep -o '`[^`]*`' | tr -d '`' || true
}

@test "An application's dashboard is delivered with it and leaves with it" {
  local apps app labels watched board boards namespace described dependencies names remaining key map marked
  built grafana
  labels="$(grafana_labels)"
  watched="$(yq -N 'select(.kind == "Grafana") | .metadata.namespace' "$BUILT")"
  # The Grafana application keeps the instance's own dashboards and no other application's: one that
  # describes an application must go with that application, so it is not kept here.
  [ "$(yq -N 'select(.kind == "GrafanaDashboard") | .metadata.name' "$BUILT" | sort | paste -sd' ' -)" = "cluster-home logs" ]
  # The operator watches its own namespace, which is the Grafana's, and no other: a dashboard
  # anywhere else would never be applied.
  built grafana-operator
  [ "$(yq -N 'select(.kind == "HelmRelease") | .metadata.namespace' "$BUILT")" = "$watched" ]
  [ "$(yq '.namespaceScope' "$REPO/kubernetes/apps/base/$NAMESPACE/grafana-operator/app/values.yaml")" = true ]
  [ "$(yq '.watchNamespaces // ""' "$REPO/kubernetes/apps/base/$NAMESPACE/grafana-operator/app/values.yaml")" = "" ]

  pinned_apps
  apps="$DASHBOARD_APPS"
  for app in $apps; do
    built "$app"
    boards="$(yq -N -o json -I0 'select(.kind == "GrafanaDashboard")' "$BUILT")"
    echo "$app: GrafanaDashboards: $(jq -r '.metadata.name' <<<"$boards" | paste -sd' ' -)"
    [ -n "$boards" ]
    while IFS= read -r board; do
      namespace="$(jq -r '.metadata.namespace // ""' <<<"$board")"
      echo "$app: $(jq -r '.metadata.name' <<<"$board") in ${namespace:-no namespace}, folder $(jq -r '.spec.folder // "none"' <<<"$board"), applied every $(jq -r '.spec.resyncPeriod // "never"' <<<"$board")"
      [ "$namespace" = "$watched" ]
      # The Grafana is selected by labels it has.
      jq -e --argjson labels "$labels" '(.spec.instanceSelector.matchLabels // {}) as $selector
        | ($selector | length > 0) and ($selector | to_entries | all($labels[.key] == .value))' <<<"$board"
      # It names its folder, as the operator files a dashboard that names none under its namespace,
      # and is applied again every minute, as a restarted Grafana starts without it.
      [ -n "$(jq -r '.spec.folder // ""' <<<"$board")" ]
      [ "$(jq -r '.spec.resyncPeriod // ""' <<<"$board")" = 1m ]
      # Its JSON is in the tree: a key of a ConfigMap of its own application, or the dashboard itself.
      # Flux substitutes neither: a ${...} in it is Grafana's variable.
      map="$(jq -r '.spec.configMapRef.name // ""' <<<"$board")"
      key="$(jq -r '.spec.configMapRef.key // ""' <<<"$board")"
      if [ -n "$map" ]; then
        [ "$(MAP="$map" KEY="$key" yq -N 'select(.kind == "ConfigMap" and .metadata.name == strenv(MAP)) | .data | has(strenv(KEY))' "$BUILT")" = true ]
        marked="$(MAP="$map" yq -N 'select(.kind == "ConfigMap" and .metadata.name == strenv(MAP)) | .metadata.annotations["kustomize.toolkit.fluxcd.io/substitute"] // ""' "$BUILT")"
      else
        [ "$(jq -r '.spec.json // "" | length' <<<"$board")" -gt 0 ]
        marked="$(jq -r '.metadata.annotations["kustomize.toolkit.fluxcd.io/substitute"] // ""' <<<"$board")"
      fi
      [ "$marked" = disabled ]
    done <<<"$boards"
  done

  # What each application's dashboard describes, and what happens to the dashboard without it. The
  # Grafana's own are the instance's: they go with the Grafana.
  names="$(overlay_names "$REPO/kubernetes/apps/overlays/lab-sto2")"
  for app in $apps; do
    [ "$app" = grafana ] && continue
    described="${app%-dashboard}"
    # The log store keeps its dashboard beside its release; every other dashboard is an application
    # of its own, named after the one it describes, so that no monitor, alert or controller waits
    # for the Grafana operator.
    [ "$described" != "$app" ] || [ "$app" = victoria-logs ]
    app_dir "$app"
    [ "$(yq '.spec.targetNamespace' "$REPO/$APP_DIR/ks.yaml")" = "$watched" ]
    dependencies="$(yq '.spec.dependsOn // [] | .[].name' "$REPO/$APP_DIR/ks.yaml" | paste -sd' ' -)"
    echo "$app describes $described and waits for: $dependencies"
    # The kind exists once the operator's release is Ready.
    [[ " $dependencies " == *" grafana-operator "* ]]
    if [ "$described" != "$app" ]; then
      # A dashboard of its own application, in the namespace the operator watches, waits for what it
      # describes, and kubernetes-check refuses a cluster that enables it without that.
      [[ " $dependencies " == *" $described "* ]]
      # What it waits for is Ready only once what it applies is, which kubernetes-check requires of
      # every dependency.
      kustomize build --load-restrictor LoadRestrictionsNone "$REPO/kubernetes/apps/overlays/lab-sto2" |
        NAME="$described" yq -N -o json -I0 'select(.kind == "Kustomization" and .metadata.name == strenv(NAME))' |
        jq -e '.spec.wait == true or ((.spec.healthChecks // []) | length > 0) or ((.spec.healthCheckExprs // []) | length > 0)' ||
        { echo "$described, which $app waits for, does not wait"; return 1; }
    fi
    [[ " $names " == *" $described "* ]]
    [[ " $names " == *" $app "* ]]
    without "$BATS_TEST_TMPDIR/without" "$described" "$app"
    remaining="$(overlay_names "$WITHOUT")"
    echo "the overlay without $described and $app has $(wc -w <<<"$remaining") Kustomizations, from $(wc -w <<<"$names")"
    [[ " $remaining " != *" $app "* ]]
    [[ " $remaining " != *" $described "* ]]
    if [ "$described" != "$app" ]; then
      without "$BATS_TEST_TMPDIR/without-only" "$described"
      run "$REPO/scripts/kubernetes-check" "$BATS_TEST_TMPDIR/without-only"
      echo "$output"
      [ "$status" -ne 0 ]
      [[ $output == *"Kustomization $app names $described in dependsOn"* ]]
    fi
  done
}

@test "A dashboard is pinned to an upstream revision the tree records, and nothing is fetched that the tree did not pin" {
  local app described board map key name file record version source licence sha path pin fetched inline unaccounted types repository upstream_path tag count=0 own="" upstream=""
  pinned_apps
  for app in $DASHBOARD_APPS; do
    built "$app"
    # No dashboard loads from the network at run time, nor asks Grafana to install a plugin. jq reads
    # the condition: yq binds or looser than a pipe, and reads .spec | has(a) or has(b) as
    # (.spec | has(a)) or has(b), b of the whole object.
    fetched="$(yq -N -o json -I0 'select(.kind == "GrafanaDashboard")' "$BUILT" | jq -r 'select(.spec // {}
      | has("url") or has("urlAuthorization") or has("grafanaCom") or has("oci") or has("jsonnet") or has("jsonnetLib")
        or (.plugins // [] | length > 0)) | .metadata.name')"
    echo "$app: fetched at run time: ${fetched:-none}"
    [ -z "$fetched" ]
    # The Grafana's own dashboards are written in this repository; every other application's is a
    # file in a ConfigMap: one of those written for this tree, or an upstream file, which its
    # GrafanaDashboard records.
    [ "$app" = grafana ] && continue
    inline="$(yq -N 'select(.kind == "GrafanaDashboard" and .spec.configMapRef == null) | .metadata.name' "$BUILT")"
    echo "$app: dashboards not from a ConfigMap: ${inline:-none}"
    [ -z "$inline" ]
    described="${app%-dashboard}"
    # What it describes is scraped: the cluster's render holds a monitor of that application.
    cluster_render </dev/null
    compgen -G "$CLUSTER_RENDER/$described/*Monitor.monitoring.coreos.com_*.yaml" >/dev/null ||
      { echo "$described: no monitor in the render"; return 1; }
    while IFS=$'\t' read -r board map key; do
      [ -n "$board" ] || continue
      file="$(board_file "$app" "$board")"
      [ "$key" = "$board.json" ] || [ "$app" = victoria-logs ]
      if [[ " $OWN_DASHBOARDS " == *" $board "* ]]; then
        # Written for this tree: it has no upstream, and so no record of one.
        echo "$board ($key): written for this tree, in $file"
        [ -z "$(record "$file" Source)$(record "$file" SHA-256)$(record "$file" Chart-path)$(record "$file" "dashboard-[a-z0-9-]+")" ]
        own+=" $board"
        continue
      fi
      count=$((count + 1))
      name="dashboard-${key%.json}"
      echo "$board ($key): recorded as $name in $file"
      record="$(grep -E "^[[:blank:]]*#[[:blank:]]*$name:[[:blank:]]*v?[0-9]+(\.[0-9]+)+[[:blank:]]*\$" "$REPO/$file")"
      [ "$(grep -c . <<<"$record")" -eq 1 ]
      version="$(sed -E 's/^[[:blank:]]*#[[:blank:]]*[a-z0-9-]+:[[:blank:]]*//; s/[[:blank:]]*$//' <<<"$record")"
      source="$(grep -E '^[[:blank:]]*#[[:blank:]]*Source:[[:blank:]]*https://' "$REPO/$file" | sed -E 's/^[^:]*:[[:blank:]]*//')"
      licence="$(grep -E '^[[:blank:]]*#[[:blank:]]*Licence:[[:blank:]]*[A-Za-z0-9.-]+[[:blank:]]*$' "$REPO/$file" | sed -E 's/^[^:]*:[[:blank:]]*//')"
      sha="$(grep -E '^[[:blank:]]*#[[:blank:]]*SHA-256:[[:blank:]]*[0-9a-f]{64}[[:blank:]]*$' "$REPO/$file" | sed -E 's/^[^:]*:[[:blank:]]*//')"
      path="$(record "$file" Chart-path)"
      echo "  revision $version, source ${source:-none}, licence ${licence:-none}, SHA-256 ${sha:-none}, path in the chart ${path:-none}"
      [ "$(grep -c . <<<"$source")" -eq 1 ]
      [ "$(grep -c . <<<"$licence")" -eq 1 ]
      [ "$(grep -c . <<<"$sha")" -eq 1 ]
      # A licence under which the file may be copied into this tree.
      [[ " $LICENCES " == *" $licence "* ]]
      # The source is a file of a public repository at the tag of the revision recorded.
      [[ $source == */blob/*"${version#v}"/* && $source != */blob/main/* && $source != */blob/master/* ]]
      # Of the repository the tests pin for the dashboard.
      repository="$(tr ' ' '\n' <<<"$UPSTREAM_REPOSITORIES" | awk -F= -v name="$board" '$1 == name { print $2 }')"
      [ -n "$repository" ] || { echo "$board: the tests pin no repository for it"; return 1; }
      [[ $source == "$repository/blob/"* ]] || { echo "$board: its source is no file of $repository"; return 1; }
      # And is the file the tests pin for it, at that tag.
      upstream_path="$(tr ' ' '\n' <<<"$UPSTREAM_PATHS" | awk -F= -v name="$board" '$1 == name { print $2 }')"
      [ -n "$upstream_path" ] || { echo "$board: the tests pin no path for it"; return 1; }
      tag="${source#"$repository/blob/"}"
      tag="${tag%%/*}"
      [ "$source" = "$repository/blob/$tag/$upstream_path" ] || { echo "$board: its source is not $upstream_path of $repository"; return 1; }
      upstream+=" $board"
      # The file is the upstream's, unchanged: its bytes are what the record says.
      [ "$(configmap_value "$BUILT" "$map" "$key" | sha256sum | cut -d' ' -f1)" = "$sha" ]
      # The revision is the one what it describes is released at, so a new chart brings this record
      # to the front of the pull request: for a file the pinned chart carries, the version of the
      # chart directory that holds it; for any other, the pinned chart's tag or the version of the
      # application the chart declares.
      chart "$(pinned_by "$described")"
      if [ -z "$path" ]; then
        echo "  $(pinned_by "$described")'s chart: $CHART_TAG, application $CHART_APP_VERSION"
        [ "$version" = "$CHART_TAG" ] || [ "$version" = "$CHART_APP_VERSION" ]
      else
        held_at "$CHART" "$path"
        echo "  $(pinned_by "$described")'s chart $CHART_TAG holds it under $HELD_BY, at version $HELD_AT"
        [ "$version" = "$HELD_AT" ]
      fi
      built "$app"
      # Renovate moves none of it: the pin check holds the record as one moved by hand.
      pin="$(awk -F'\t' -v file="$file" -v name="$name" '$1 == file && $2 == name' "$REPO/.renovate/by-hand.tsv")"
      [ -n "$pin" ] || { echo "no row of .renovate/by-hand.tsv for $name in $file"; return 1; }
    done < <(yq -N -o json -I0 'select(.kind == "GrafanaDashboard" and .spec.configMapRef != null)' "$BUILT" |
      jq -r '[.metadata.name, .spec.configMapRef.name, .spec.configMapRef.key] | @tsv')
  done
  echo "dashboards from an upstream file: $count; written for this tree:$own"
  [ "$count" -ge 6 ]
  # Each upstream dashboard has its repository and its path pinned, and the tests pin none for another.
  [ "$(tr ' ' '\n' <<<"$upstream" | grep . | sort | paste -sd' ' -)" = "$(tr ' ' '\n' <<<"$UPSTREAM_REPOSITORIES" | cut -d= -f1 | paste -sd' ' -)" ]
  [ "$(tr ' ' '\n' <<<"$upstream" | grep . | sort | paste -sd' ' -)" = "$(tr ' ' '\n' <<<"$UPSTREAM_PATHS" | cut -d= -f1 | paste -sd' ' -)" ]
  # The dashboards written for this tree are the pinned ones, all of them.
  [ "$(tr ' ' '\n' <<<"$own" | grep . | sort | paste -sd' ' -)" = "$OWN_DASHBOARDS" ]
  # Every dashboard the cluster renders is one of those checked above, wherever its file is named.
  cluster_render
  unaccounted="$(unaccounted_dashboards "$CLUSTER_RENDER"/*/*.yaml)"
  echo "dashboards of the cluster no check built: ${unaccounted:-none}"
  [ -z "$unaccounted" ]
  # One that is not, a dashboard fetched from a URL, is named.
  cat >"$BATS_TEST_TMPDIR/fetched.yaml" <<'YAML'
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: fetched-dashboard
spec:
  url: https://example.com/dashboard.json
YAML
  [ "$(unaccounted_dashboards "$CLUSTER_RENDER"/*/*.yaml "$BATS_TEST_TMPDIR/fetched.yaml")" = fetched-dashboard ]

  # No panel needs a plugin: each is of a type the pinned Grafana ships, or turns into one when it
  # loads the dashboard. The lists are Grafana 13's; another major is read again.
  built grafana
  [[ $(yq -N 'select(.kind == "Grafana") | .spec.version' "$BUILT") == 13.* ]]
  all_boards
  types="$(jq -r "$DASHBOARDS_JQ"'. as $board | .json // "{}" | fromjson | panels[] | "\(.type)\t\($board.name)"' "$BOARDS")"
  echo "panel types: $(cut -f1 <<<"$types" | sort | uniq -c | xargs)"
  [ "$(grep -c . <<<"$types")" -gt 100 ]
  while IFS=$'\t' read -r name board; do
    [[ " $PANEL_TYPES $MIGRATED_PANEL_TYPES " == *" $name "* ]] || { echo "$board: a panel of type $name, which Grafana does not ship"; return 1; }
  done <<<"$types"
}

@test "Every dashboard has a unique identity and reads only datasources the tree defines" {
  local problems uids total unaccounted name
  pinned_apps
  datasources
  echo "datasources of the tree: $DATASOURCES"
  [ "$(jq 'length' <<<"$DATASOURCES")" -ge 2 ]
  # The dashboards of the applications, and the monitoring chart's own, which the release of the
  # grafana application renders.
  all_boards
  total="$(grep -c . "$BOARDS")"
  echo "dashboards: $total"
  [ "$total" -gt 25 ]
  # No dashboard of the cluster is outside those read.
  cluster_render
  unaccounted="$(unaccounted_dashboards "$CLUSTER_RENDER"/*/*.yaml)"
  echo "dashboards of the cluster no check built: ${unaccounted:-none}"
  [ -z "$unaccounted" ]

  # shellcheck disable=SC2016 # jq variables.
  problems="$(jq -r --argjson datasources "$DATASOURCES" "$DASHBOARDS_JQ"'
    .name as $name | .json as $json
    | if ($json // "") == "" then "\($name): its JSON is nowhere in the tree"
      else
        # Each input the GrafanaDashboard maps is one its JSON names as ${input}, and what it maps it to
        # is a datasource of the tree, by the name the operator writes in its place, or the expression
        # datasource of Grafana, by its uid.
        (.datasources[] | . as $map
          | if (.inputName // "") == "" or (.datasourceName // "") == ""
            then "\($name): maps no input or no datasource: \(tojson)"
            elif (any($datasources[]; .name == $map.datasourceName) or $map.datasourceName == "__expr__") | not
            then "\($name): maps \(.inputName) to \(.datasourceName), a datasource the tree does not define"
            elif $json | contains("${\($map.inputName)}") | not
            then "\($name): maps \(.inputName), which its JSON never names"
            else empty end),
        (try (delivered | fromjson) catch null) as $model
        | if $model == null then "\($name): its JSON does not parse"
          elif ($model.uid // "") == "" then "\($name): no uid"
          else
            (if ($model.title // "") == "" then "\($name): no title" else empty end),
            ($model | unresolved($datasources)[] | "\($name): reads a datasource the tree does not define: \(tojson)")
          end
      end' "$BOARDS")"
  # An identity no other dashboard has: the uid, which Grafana keys a dashboard by, and the title in
  # its folder, by which the operator takes a dashboard of another uid for this one and removes it
  # (Exists and reconcileWithInstance in controllers/dashboard_controller.go of grafana-operator
  # v5.25.0). A folder is found by its title whatever its case (GetFolderUID in the same file), so
  # two spellings of a title are one folder.
  uids="$(jq -r "$DASHBOARDS_JQ"'(try (delivered | fromjson) catch {}) as $model
    | select(($model.uid // "") != "") | [$model.uid, .name, (.folder // "" | ascii_downcase), ($model.title // "")] | @tsv' "$BOARDS")"
  problems+=$'\n'"$(cut -f1 <<<"$uids" | sort | uniq -d | while read -r name; do
    echo "the uid $name is that of: $(awk -F'\t' -v uid="$name" '$1 == uid { print $2 }' <<<"$uids" | paste -sd' ' -)"
  done)"
  problems+=$'\n'"$(cut -f3,4 <<<"$uids" | sort | uniq -d | while IFS=$'\t' read -r name total; do
    echo "the title $total in the folder $name is that of: $(awk -F'\t' -v folder="$name" -v title="$total" '$3 == folder && $4 == title { print $2 }' <<<"$uids" | paste -sd' ' -)"
  done)"
  problems="$(grep -v '^$' <<<"$problems" || true)"
  echo "problems: ${problems:-none}"
  [ -z "$problems" ]
  total="$(grep -c . "$BOARDS")"
  [ "$(grep -c . <<<"$uids")" -eq "$total" ]
  # Those of the applications are among the ones read: each by its name, and the home and OpenBao's
  # by the uid each is known by.
  for name in cluster-home logs victoria-logs openbao cilium-agent piraeus cloudnative-pg falco $OWN_DASHBOARDS; do
    [ "$(awk -F'\t' -v name="$name" '$2 == name' <<<"$uids" | grep -c .)" -eq 1 ] || { echo "$name is not among the dashboards read"; return 1; }
  done
  grep -q $'^cluster-home\t' <<<"$uids"
  grep -q $'^openbao\t' <<<"$uids"

  # The rule, on dashboards of a few lines: what Grafana reads must resolve, and what it does not
  # read may name anything.
  # A row, and the target a row carries, are not read.
  [ -z "$(unresolved <<<'{"panels": [{"type": "row", "datasource": {"uid": "nowhere"}, "targets": [{"datasource": {"uid": "nowhere"}}]}]}')" ]
  # A panel inside a row is.
  [ "$(unresolved <<<'{"panels": [{"type": "row", "panels": [{"type": "stat", "datasource": {"uid": "nowhere"}}]}]}')" = '{"uid":"nowhere"}' ]
  # A panel that is no row.
  [ "$(unresolved <<<'{"panels": [{"type": "stat", "datasource": {"uid": "prometheus"}}]}')" = '{"uid":"prometheus"}' ]
  [ -z "$(unresolved <<<'{"panels": [{"type": "stat", "datasource": {"type": "prometheus", "uid": "Prometheus"}}]}')" ]
  # Grafana's own names are its built-in datasource, the mixed one and the one that reuses another
  # panel's results; no other name between dashes is one, and a panel that names it has its targets
  # read.
  [ -z "$(unresolved <<<'{"panels": [{"type": "stat", "datasource": "-- Grafana --"}, {"type": "stat", "datasource": "-- Mixed --"}, {"type": "stat", "datasource": {"uid": "-- Dashboard --"}}]}')" ]
  [ "$(unresolved <<<'{"panels": [{"type": "stat", "datasource": "-- Nowhere --", "targets": [{"datasource": {"uid": "nowhere"}}]}]}' | paste -sd' ' -)" = '"-- Nowhere --" {"uid":"nowhere"}' ]
  # A target under a panel that names one datasource is run against the panel's.
  # shellcheck disable=SC2016 # ${ds} is Grafana's variable.
  [ -z "$(unresolved <<<'{"templating": {"list": [{"name": "ds", "type": "datasource", "query": "prometheus"}]}, "panels": [{"type": "stat", "datasource": {"type": "prometheus", "uid": "${ds}"}, "targets": [{"datasource": {"type": "prometheus", "uid": "nowhere"}}]}]}')" ]
  # Not when the panel's own leads nowhere, names none, or is the mixed one.
  [ "$(unresolved <<<'{"panels": [{"type": "stat", "datasource": {"uid": "nowhere"}, "targets": [{"datasource": {"uid": "elsewhere"}}]}]}' | paste -sd' ' -)" = '{"uid":"elsewhere"} {"uid":"nowhere"}' ]
  [ "$(unresolved <<<'{"panels": [{"type": "stat", "targets": [{"datasource": {"uid": "nowhere"}}]}]}')" = '{"uid":"nowhere"}' ]
  [ "$(unresolved <<<'{"panels": [{"type": "stat", "datasource": {"type": "prometheus"}, "targets": [{"datasource": {"uid": "nowhere"}}]}]}')" = '{"uid":"nowhere"}' ]
  [ "$(unresolved <<<'{"panels": [{"type": "stat", "datasource": {"type": "datasource", "uid": "-- Mixed --"}, "targets": [{"datasource": {"uid": "nowhere"}}, {"datasource": {"type": "prometheus", "uid": "Prometheus"}}]}]}')" = '{"uid":"nowhere"}' ]
  # An expression is Grafana's own by its uid, and is read even under such a panel.
  [ -z "$(unresolved <<<'{"panels": [{"type": "stat", "datasource": {"uid": "Prometheus"}, "targets": [{"datasource": {"type": "__expr__", "uid": "__expr__"}}]}]}')" ]
  # shellcheck disable=SC2016 # ${DS_EXPRESSION} is an input the operator did not replace.
  [ "$(unresolved <<<'{"panels": [{"type": "stat", "datasource": {"uid": "Prometheus"}, "targets": [{"datasource": {"type": "__expr__", "uid": "${DS_EXPRESSION}"}}]}]}')" = '{"type":"__expr__","uid":"${DS_EXPRESSION}"}' ]
  # A variable's and an annotation's are read.
  [ "$(unresolved <<<'{"templating": {"list": [{"type": "query", "datasource": {"uid": "nowhere"}}]}, "annotations": {"list": [{"datasource": {"uid": "elsewhere"}}]}}' | paste -sd' ' -)" = '{"uid":"elsewhere"} {"uid":"nowhere"}' ]
}

@test "The home dashboard queries only metrics the cluster scrapes" {
  local uid name found problems
  built grafana
  uid="$(yq -N 'select(.kind == "Grafana") | .spec.preferences.homeDashboardUid // ""' "$BUILT")"
  echo "the Grafana's home dashboard: ${uid:-none}"
  [ -n "$uid" ]
  # The home dashboard is one of the instance's own, carried in its GrafanaDashboard.
  kept
  name="$(UID_="$uid" jq -r 'select(.model.uid == env.UID_ and .app == "grafana") | .name' "$KEPT")"
  [ "$name" = cluster-home ]
  # It is in the folder docs/kubernetes.md (Dashboards) names for it, not the namespace's.
  [ "$(yq -N 'select(.kind == "GrafanaDashboard" and .metadata.name == "cluster-home") | .spec.folder' "$BUILT")" = General ]

  # Where each metric comes from, in tests/fixtures/dashboards/metric-sources.tsv: a monitor of the
  # render that scrapes the target that serves it, a monitor of any kind for up, or an alerting rule
  # for the series Prometheus writes for each alert. A series a recording rule of the render writes
  # needs no row.
  datasources
  scrape
  echo "monitors in the render: $(jq 'length' "$MONITORS"); recording rules: $(jq '.records | length' "$RULES"); alerting rules: $(jq '.alerts | length' "$RULES")"
  [ "$(jq 'length' "$MONITORS")" -gt 0 ]
  found="$(scraped "$KEPT" "$TABLE" "$MONITORS" "$RULES" "$name")"
  echo "$found"
  [ "$(grep '^read: ' <<<"$found" | sed 's/^read: [^ ]* //' | jq '.expressions')" -ge 6 ]
  [ "$(grep -c '^known: ' <<<"$found")" -ge 6 ]
  [ "$(grep -c '^problem: ' <<<"$found")" -eq 0 ]

  # It defines no variable but its datasource: a variable inside a string is read as the string, and
  # Grafana escapes no double quote of its value, so a value with one could end the string and leave
  # the rest of it a query the check does not read.
  problems="$(home_problems "$KEPT")"
  echo "problems: ${problems:-none}"
  [ -z "$problems" ]
  # shellcheck disable=SC2016 # Grafana's variables.
  jq -c 'if .name == "cluster-home" then .model.templating.list += [{"type": "custom", "name": "v", "query": "x\"} or unscraped_thing_total{a=\""}]
    | .model.panels[0].targets[0].expr = "count({job=\"$v\"})" else . end' "$KEPT" >"$BATS_TEST_TMPDIR/mutant-home.jsonl"
  problems="$(home_problems "$BATS_TEST_TMPDIR/mutant-home.jsonl")"
  echo "with a custom variable: ${problems:-none}"
  [ "$problems" = "cluster-home: it defines the variable v, of type custom, and may define none but its datasource" ]
}

@test "A dashboard too large for its delivery fails the checks" {
  local app files="" padded="$BATS_TEST_TMPDIR/padded.json" largest
  pinned_apps
  for app in $DASHBOARD_APPS; do
    built "$app"
    files+=" $BUILT"
  done
  render grafana
  # Every dashboard of the tree, the monitoring chart's included, fits its delivery.
  # shellcheck disable=SC2086 # The names hold no space.
  oversized $files "$RENDERED"
  # And no dashboard of the cluster is outside those.
  cluster_render
  [ -z "$(unaccounted_dashboards "$CLUSTER_RENDER"/*/*.yaml)" ]
  # The largest of the tree's own is a real dashboard, and has room left.
  # shellcheck disable=SC2086
  largest="$(yq -N -o json -I0 'select(.kind == "ConfigMap") | .data // {} | .[]' $files | jq -r 'utf8bytelength' | sort -n | tail -1)"
  echo "the largest dashboard of the tree's own: $largest bytes of $CONFIGMAP_LIMIT"
  [ "$largest" -gt 10000 ]
  [ "$largest" -lt "$CONFIGMAP_LIMIT" ]
  # A dashboard padded past the ceiling is refused, with its ConfigMap named.
  jq -n --argjson limit "$CONFIGMAP_LIMIT" '{apiVersion: "v1", kind: "ConfigMap", metadata: {name: "padded-dashboard"},
    data: {"padded.json": ("{\"panels\": [], \"description\": \"" + (" " * ($limit + 1)) + "\"}")}}' >"$padded"
  run oversized "$padded"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"ConfigMap/padded-dashboard"* ]]
  # And a GrafanaDashboard that carries more than that in its own JSON.
  jq -n --argjson limit "$CONFIGMAP_LIMIT" '{apiVersion: "grafana.integreatly.org/v1beta1", kind: "GrafanaDashboard",
    metadata: {name: "padded-inline"}, spec: {json: ("{\"description\": \"" + (" " * ($limit + 1)) + "\"}")}}' >"$padded"
  run oversized "$padded"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"GrafanaDashboard/padded-inline"* ]]
}

@test "A dashboard the pinned chart carries is the chart's file, byte for byte" {
  local app described board map key file path version sha root member carried="" theirs="$BATS_TEST_TMPDIR/theirs.json" ours="$BATS_TEST_TMPDIR/ours.json"
  pinned_apps
  for app in $DASHBOARD_APPS; do
    [ "$app" = grafana ] && continue
    described="${app%-dashboard}"
    built "$app"
    while IFS=$'\t' read -r board map key; do
      [ -n "$board" ] || continue
      [[ " $OWN_DASHBOARDS " == *" $board "* ]] && continue
      file="$(board_file "$app" "$board")"
      path="$(record "$file" Chart-path)"
      sha="$(record "$file" SHA-256)"
      version="$(record "$file" "dashboard-${key%.json}")"
      built "$app"
      configmap_value "$BUILT" "$map" "$key" >"$ours"
      # The chart that releases what the dashboard describes, as the tests pull it at its pinned tag.
      chart "$(pinned_by "$described")"
      root="$(tar -tzf "$CHART" | head -1 | cut -d/ -f1)"
      if [ -z "$path" ]; then
        # Not a file the chart carries: none of the chart's JSON files is what the record says.
        while IFS= read -r member; do
          [ "$(tar -xzOf "$CHART" "$member" | sha256sum | cut -d' ' -f1)" != "$sha" ] ||
            { echo "$board: $(pinned_by "$described")'s chart carries the file as ${member#"$root"/}: record it as Chart-path"; return 1; }
        done < <(tar -tzf "$CHART" | grep '\.json$' || true)
        echo "$board: no file of $(pinned_by "$described")'s chart $CHART_TAG"
        continue
      fi
      carried+=" $board"
      [ "$(grep -c . <<<"$path")" -eq 1 ]
      [[ $path != /* && /$path/ != */../* ]]
      # The same bytes as the chart's file.
      tar -xzOf "$CHART" "$root/$path" >"$theirs"
      echo "$board: $path of $(pinned_by "$described")'s chart $CHART_TAG: $(wc -c <"$theirs") bytes, ours $(wc -c <"$ours")"
      [ -s "$theirs" ]
      cmp "$theirs" "$ours"
      # The source the record names is that path of the chart's repository.
      [[ $(record "$file" Source) == */"$path" ]]
      # The revision is the version of the chart directory that holds the file: the nearest one above
      # it with a Chart.yaml, the chart's own or that of a chart it carries under charts/.
      held_at "$CHART" "$path"
      echo "  held by $HELD_BY: version $HELD_AT; recorded $version"
      [ "$version" = "$HELD_AT" ]
    done < <(yq -N -o json -I0 'select(.kind == "GrafanaDashboard" and .spec.configMapRef != null)' "$BUILT" |
      jq -r '[.metadata.name, .spec.configMapRef.name, .spec.configMapRef.key] | @tsv')
  done
  # The dashboards held to their chart are the pinned ones: a record that loses its path is missed.
  echo "dashboards the pinned chart carries:$carried"
  [ "$(tr ' ' '\n' <<<"$carried" | grep . | sort | paste -sd' ' -)" = "$CHART_CARRIED" ]
}

@test "Every dashboard the tree keeps queries only metrics the cluster scrapes" {
  local found names mutant="$BATS_TEST_TMPDIR/mutant"
  # What the parser reads of an expression, on literal ones.
  [ "$(metrics <<<'sum by (job) (rate(a_total{job="x"}[5m])) / on (job) group_left (team) b:c:rate5m' | paste -sd' ' -)" = "a_total b:c:rate5m" ]
  # The words PromQL keeps, in any case, and functions.
  [ "$(metrics <<<'max(a) OR (b AND c) UNLESS d or vector(0)' | paste -sd' ' -)" = "a b c d" ]
  [ "$(metrics <<<'SUM BY (x) (a) > BOOL 1 and b == +Inf or c != NaN' | paste -sd' ' -)" = "a b c" ]
  # group_left and group_right without a label list, and with one.
  [ "$(metrics <<<'a * on (x) group_left b + c * ignoring (y) GROUP_RIGHT d' | paste -sd' ' -)" = "a b c d" ]
  [ "$(metrics <<<'a * on(node,instance) group_left(label_zone) b' | paste -sd' ' -)" = "a b" ]
  # Strings, in each of PromQL's quotes, hold no metric, nor do comments.
  # shellcheck disable=SC2016 # The backticks are a PromQL quote, not a command.
  [ "$(metrics <<<'label_replace(a{x="not_a_metric{", y=~`also_not`}, "dst", "$1", "src", '\''(.*)_no'\'') # nor_this' | paste -sd' ' -)" = "a" ]
  # Ranges, subqueries, offsets and times.
  # shellcheck disable=SC2016 # Grafana's variables, here and below, not the shell's.
  [ "$(metrics <<<'max_over_time(rate(a[5m])[1h:1m]) - b offset 1h30m + c @ end() + d[$__rate_interval]' | paste -sd' ' -)" = "a b c d" ]
  # Grafana's variables as a range or a matcher's value, and its own, $__..., as a scalar, name no
  # metric. Any other variable that stands where a metric may, a number's among them, is a name the
  # text does not give.
  # shellcheck disable=SC2016
  [ "$(metrics <<<'topk($top, increase(a{pod=~"$pod"}[${__range}])) * $__interval_ms + b{c="[[d]]"}' | paste -sd' ' -)" = 'a b unread: ${top}' ]
  # shellcheck disable=SC2016
  [ "$(metrics <<<'sum($m)' | paste -sd' ' -)" = 'unread: ${m}' ]
  # So is one inside a selector's braces outside a string: a whole matcher, a label's name or a value
  # without quotes. Grafana puts a whole matcher a variable holds in as it is, so it may be one on
  # __name__.
  # shellcheck disable=SC2016
  [ "$(metrics <<<'count({$m} == 1) or vector(0)' | paste -sd' ' -)" = 'unread: ${m}' ]
  # shellcheck disable=SC2016
  [ "$(metrics <<<'sum(rate({$m}[5m])) + sum({x="y", $m})' | paste -sd' ' -)" = 'unread: ${m}' ]
  # shellcheck disable=SC2016
  [ "$(metrics <<<'a{${n:raw}} + b{$l="c"} + d{e=$v, f=~"$w"}' | paste -sd' ' -)" = 'a b d unread: ${l} unread: ${n} unread: ${v}' ]
  # In a label list or as an offset it names none.
  # shellcheck disable=SC2016
  [ "$(metrics <<<'max by ($label) (${n:raw}) / ignoring ($other) c offset $shift' | paste -sd' ' -)" = 'c unread: ${n}' ]
  # A selector by __name__ with = names its metric; with a regular expression it is not read.
  [ "$(metrics <<<'{__name__="a_total", job="x"} + b' | paste -sd' ' -)" = "a_total b" ]
  [ "$(metrics <<<'{__name__=~"a_(b|c)_total", job="x"} + d' | paste -sd' ' -)" = "d unread: __name__" ]
  [ "$(metrics <<<'{__name__!="a"}' | paste -sd' ' -)" = "unread: __name__" ]
  # Each the same with a comment inside the braces, which PromQL admits there.
  [ "$(metrics <<<$'{__name__ # the name\n= "a_total"} + b' | paste -sd' ' -)" = "a_total b" ]
  [ "$(metrics <<<$'{__name__ # the names\n=~ "a_.*"} + b' | paste -sd' ' -)" = "b unread: __name__" ]
  # A string is read from its first quote to its own closing one, whatever quotes it holds, and so is
  # a comment, to the end of its line.
  [ "$(metrics <<<"{x='\"'} + a_total{y='\"'}" | paste -sd' ' -)" = "a_total" ]
  [ "$(metrics <<<$'a # it\'s\n+ b # and c\'s\n+ c' | paste -sd' ' -)" = "a b c" ]
  # A name a variable completes, or stands for, is not read; the rest of the expression is.
  # shellcheck disable=SC2016
  [ "$(metrics <<<'rate(a_${mount}_count{x="y"}[1m]) / b' | paste -sd' ' -)" = 'b unread: ${mount}' ]
  # shellcheck disable=SC2016
  [ "$(metrics <<<'[[prefix]]_total + $metric{x="y"} + c' | paste -sd' ' -)" = 'c unread: ${metric} unread: ${prefix}' ]
  # A metric named in quotes is not read at all: the expression is refused. So is a label named in
  # quotes, which Prometheus 3 admits with any of PromQL's quotes and escapes, as __name__ may be.
  run metrics <<<'{"a.metric", job="x"}'
  [ "$status" -ne 0 ]
  run metrics <<<'{"__name__"="a_total"} + b'
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"names a metric or a label in quotes"* ]]
  # shellcheck disable=SC2016 # The backticks are a PromQL quote, not a command.
  for quoted in "'__name__'" '`__name__`' '"__n\x61me__"' '"job"'; do
    run metrics <<<"a{$quoted=\"x\"}"
    [ "$status" -ne 0 ] || { echo "a{$quoted=\"x\"} is read"; return 1; }
  done
  # The query of a variable, in each form.
  [ "$(variable_metrics <<<'label_values(a{b="c,d"}, pod)')" = a ]
  [ "$(variable_metrics <<<'label_values(a, pod)')" = a ]
  [ -z "$(variable_metrics <<<'label_values(pod)')" ]
  [ -z "$(variable_metrics <<<'label_names()')" ]
  [ "$(variable_metrics <<<'query_result(count by (x) (a) > b)' | paste -sd' ' -)" = "a b" ]
  # shellcheck disable=SC2016
  [ "$(variable_metrics <<<'a{b=~"$c", d=~"$e-([1-9][0-9]*)$"}')" = a ]
  run variable_metrics <<<'metrics(a_.*)'
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"is none of label_values"* ]]
  # What the check reads of a monitor's metricRelabelings, on a literal one: the names a rule on
  # __name__ alone drops and those it keeps, whatever the case of its action, with Prometheus' (.*)
  # where the rule gives no regex; not a rule on more labels, nor one of another action.
  cat >"$BATS_TEST_TMPDIR/relabeled.yaml" <<'YAML'
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: literal
spec:
  podMetricsEndpoints:
    - metricRelabelings:
        - {action: Drop, sourceLabels: [__name__], regex: a_.*}
        - {action: drop, sourceLabels: [__name__, job], regex: b;x}
        - {action: replace, sourceLabels: [__name__], targetLabel: c}
    - metricRelabelings:
        - {action: drop, sourceLabels: [__name__]}
        - {action: Keep, sourceLabels: [__name__], regex: d|e}
YAML
  run relabeled "$BATS_TEST_TMPDIR/relabeled.yaml"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$output" = '[{"id":"PodMonitor/literal","drops":["a_.*","(.*)"],"keeps":["d|e"]}]' ]

  pinned_apps
  kept
  datasources
  scrape
  # Which datasource the check takes an expression for, on dashboards of a few lines, as Grafana
  # finds it: by the uid or name a reference gives, whatever type it gives with it, and by the type
  # only where it gives no uid.
  [ "$(queried <<<'{"panels": [{"type": "stat", "datasource": {"type": "victoriametrics-logs-datasource", "uid": "Prometheus"}, "targets": [{"expr": "a"}]}]}')" = "1 0" ]
  [ "$(queried <<<'{"panels": [{"type": "stat", "datasource": {"type": "prometheus", "uid": "VictoriaLogs"}, "targets": [{"expr": "a"}]}]}')" = "0 1" ]
  [ "$(queried <<<'{"panels": [{"type": "stat", "datasource": {"type": "victoriametrics-logs-datasource", "uid": ""}, "targets": [{"expr": "a"}]}, {"type": "stat", "datasource": {"type": "prometheus"}, "targets": [{"expr": "b"}]}]}')" = "1 1" ]
  [ "$(queried <<<'{"panels": [{"type": "stat", "datasource": {"uid": "-- Mixed --"}, "targets": [{"datasource": {"type": "victoriametrics-logs-datasource", "uid": "Prometheus"}, "expr": "a"}]}], "annotations": {"list": [{"datasource": {"type": "victoriametrics-logs-datasource", "uid": "Prometheus"}, "expr": "b"}]}}')" = "2 0" ]
  names="$(jq -r .name "$KEPT" | sort | paste -sd' ' -)"
  echo "dashboards the tree keeps: $names"
  # Those of the applications that deliver one, the home and the logs dashboard among them.
  [ "$names" = "$(tr ' ' '\n' <<<"cluster-home logs victoria-logs openbao cilium-agent piraeus cloudnative-pg falco $OWN_DASHBOARDS" | sort | paste -sd' ' -)" ]
  found="$(scraped "$KEPT" "$TABLE" "$MONITORS" "$RULES")"
  grep -v '^known: ' <<<"$found"
  echo "metrics with their source: $(grep -c '^known: ' <<<"$found")"
  [ "$(grep -c '^problem: ' <<<"$found")" -eq 0 ]
  [ "$(grep -c '^known: ' <<<"$found")" -gt 200 ]
  # Every dashboard but the logs one, whose targets are LogsQL, asks Prometheus something.
  [ "$(grep '^read: ' <<<"$found" | sed 's/^read: [^ ]* //' | jq -s 'map(select(.expressions == 0)) | length')" -eq 1 ]
  [ "$(grep '^read: logs: ' <<<"$found" | sed 's/^read: [^ ]* //' | jq -c '[.expressions, .variables, .other]')" = "[0,0,3]" ]

  # The check's own proof, each on a copy with one thing changed: it names the dashboard and what
  # is wrong.
  # A panel of a dashboard written for this tree on a metric no row names.
  jq -c 'if .name == "cert-manager" then .model.panels += [{"type": "stat", "datasource": {"type": "prometheus", "uid": "${datasource}"},
    "targets": [{"expr": "sum(unscraped_thing_total)"}]}] else . end' "$KEPT" >"$mutant-panel.jsonl"
  found="$(scraped "$mutant-panel.jsonl" "$TABLE" "$MONITORS" "$RULES" | grep '^problem: ')"
  echo "$found"
  [ "$found" = "problem: cert-manager: unscraped_thing_total: no row of the table names it, and no rule records it" ]
  # And on a metric a variable stands for, which one written for this tree may not have; in an
  # upstream file the table would pin it.
  # shellcheck disable=SC2016 # Grafana's variables.
  jq -c 'if .name == "cert-manager" then (.model.templating.list += [{"type": "custom", "name": "m", "query": "unscraped_thing_total"}]
    | .model.panels += [{"type": "stat", "datasource": {"type": "prometheus", "uid": "${datasource}"}, "targets": [{"expr": "sum($m)"}]}]) else . end' "$KEPT" >"$mutant-variable.jsonl"
  found="$(scraped "$mutant-variable.jsonl" "$TABLE" "$MONITORS" "$RULES" | grep '^problem: ')"
  echo "$found"
  # shellcheck disable=SC2016
  [ "$found" = 'problem: cert-manager: 1 expressions name a metric by ${m}, which a dashboard written for this tree may not' ]
  # shellcheck disable=SC2016
  jq -c 'if .name == "falco" then .model.panels += [{"type": "stat", "datasource": {"type": "prometheus", "uid": "Prometheus"}, "targets": [{"expr": "sum($m)"}]}] else . end' "$KEPT" >"$mutant-upstream-variable.jsonl"
  found="$(scraped "$mutant-upstream-variable.jsonl" "$TABLE" "$MONITORS" "$RULES" | grep '^problem: ')"
  echo "$found"
  # shellcheck disable=SC2016
  [ "$found" = 'problem: falco: 1 expressions name a metric by ${m}, which the check does not read: the table pins no unread:1 for ${m}' ]
  # The same with a variable that stands as a whole matcher inside a selector's braces and holds one on
  # __name__, which Grafana runs as count({__name__="unscraped_thing_total"} == 1).
  for name in cert-manager falco; do
    # shellcheck disable=SC2016 # Grafana's variables.
    NAME="$name" jq -c 'if .name == env.NAME then (.model.templating.list += [{"type": "custom", "name": "m", "query": "__name__=\"unscraped_thing_total\"", "hide": 2}]
      | .model.panels += [{"type": "stat", "datasource": {"type": "prometheus", "uid": "${datasource}"}, "targets": [{"expr": "count({$m} == 1) or vector(0)"}]}]) else . end' "$KEPT" >"$mutant-matcher.jsonl"
    found="$(scraped "$mutant-matcher.jsonl" "$TABLE" "$MONITORS" "$RULES" | grep '^problem: ')"
    echo "$found"
    if [ "$name" = cert-manager ]; then
      # shellcheck disable=SC2016
      [ "$found" = 'problem: cert-manager: 1 expressions name a metric by ${m}, which a dashboard written for this tree may not' ]
    else
      # shellcheck disable=SC2016
      [ "$found" = 'problem: falco: 1 expressions name a metric by ${m}, which the check does not read: the table pins no unread:1 for ${m}' ]
    fi
  done
  # A variable of a dashboard named as Grafana's own are, $__..., which the check does not read where
  # it stands for a name, is refused, in a dashboard written for this tree or an upstream file.
  for name in cert-manager falco; do
    # shellcheck disable=SC2016 # Grafana's variables.
    NAME="$name" jq -c 'if .name == env.NAME then (.model.templating.list += [{"type": "custom", "name": "__m", "query": "unscraped_thing_total"}]
      | .model.panels += [{"type": "stat", "datasource": {"type": "prometheus", "uid": "${datasource}"}, "targets": [{"expr": "sum($__m)"}]}]) else . end' "$KEPT" >"$mutant-grafana-variable.jsonl"
    found="$(scraped "$mutant-grafana-variable.jsonl" "$TABLE" "$MONITORS" "$RULES" | grep '^problem: ')"
    echo "$found"
    # shellcheck disable=SC2016
    [ "$found" = "problem: $name: variable __m: the check takes \$__... for Grafana's own and does not read it" ]
  done
  # A panel whose reference names Prometheus by its uid or name, with the type of another datasource,
  # in an upstream file whose record is its hash alone: Grafana runs it against Prometheus.
  jq -c 'if .name == "piraeus" then .model.panels += [{"type": "stat", "datasource": {"type": "victoriametrics-logs-datasource", "uid": "Prometheus"},
    "targets": [{"expr": "sum(unscraped_thing_total)"}]}] else . end' "$KEPT" >"$mutant-reference.jsonl"
  found="$(scraped "$mutant-reference.jsonl" "$TABLE" "$MONITORS" "$RULES" | grep '^problem: ')"
  echo "$found"
  [ "$found" = "problem: piraeus: unscraped_thing_total: no row of the table names it, and no rule records it" ]
  # A row that names a monitor the render lacks.
  sed -E 's|^(external-dns\t[^\t]+\t)ServiceMonitor/external-dns(\t.*)?$|\1ServiceMonitor/no-such-monitor\2|' "$TABLE" >"$mutant-monitor.tsv"
  if cmp -s "$TABLE" "$mutant-monitor.tsv"; then echo "the table has no such row to change"; return 1; fi
  found="$(scraped "$KEPT" "$mutant-monitor.tsv" "$MONITORS" "$RULES" | grep '^problem: ')"
  echo "$found"
  [ "$(grep -c . <<<"$found")" -ge 1 ]
  [ "$(grep -c -v '^problem: external-dns: external_dns_[a-z_]*: ServiceMonitor/no-such-monitor is not in the render$' <<<"$found")" -eq 0 ]
  # A row nothing reads, and a none row for a dashboard written for this tree.
  { cat "$TABLE"; printf 'flux\tflux_nothing_reads_this\tServiceMonitor/flux-operator\n'; } >"$mutant-unread.tsv"
  found="$(scraped "$KEPT" "$mutant-unread.tsv" "$MONITORS" "$RULES" | grep '^problem: ')"
  echo "$found"
  [[ $found == "problem: flux: line "*": flux_nothing_reads_this matches nothing the dashboard reads" ]]
  sed -E 's|^(cilium-bgp\tup\t)any-monitor(\t.*)?$|\1none\tnothing serves it|' "$TABLE" >"$mutant-none.tsv"
  if cmp -s "$TABLE" "$mutant-none.tsv"; then echo "the table has no such row to change"; return 1; fi
  found="$(scraped "$KEPT" "$mutant-none.tsv" "$MONITORS" "$RULES" | grep '^problem: ')"
  echo "$found"
  [[ $found == "problem: cilium-bgp: line "*": a dashboard written for this tree names each metric literally, with the monitor that scrapes it" ]]
  # A monitor that drops a metric a dashboard reads.
  jq -c 'map(if .id == "PodMonitor/silence-operator" then .drops += ["workqueue_.*"] else . end)' "$MONITORS" >"$mutant-drop.json"
  found="$(scraped "$KEPT" "$TABLE" "$mutant-drop.json" "$RULES" | grep '^problem: ')"
  echo "$found"
  [ "$found" = "problem: silence-operator: workqueue_depth: PodMonitor/silence-operator drops it, by a metricRelabelings rule on __name__" ]
  # And one that keeps only names other than one a dashboard reads.
  jq -c 'map(if .id == "PodMonitor/cilium-agent" then .keeps += ["cilium_bgp_control_plane_session_state|up"] else . end)' "$MONITORS" >"$mutant-keep.json"
  found="$(scraped "$KEPT" "$TABLE" "$mutant-keep.json" "$RULES" cilium-bgp | grep '^problem: ')"
  echo "$found"
  [ "$found" = "problem: cilium-bgp: cilium_bgp_control_plane_advertised_routes: PodMonitor/cilium-agent drops it, by a metricRelabelings rule on __name__" ]
  # The text a variable of OpenBao's dashboard holds, changed: the names it completes are no longer
  # the ones the table names.
  jq -c 'if .name == "openbao" then (.model.templating.list[] | select(.name == "metrics_prefix")) |= (.query = "other" | .current.value = "other") else . end' "$KEPT" >"$mutant-prefix.jsonl"
  found="$(scraped "$mutant-prefix.jsonl" "$TABLE" "$MONITORS" "$RULES" | grep '^problem: ')"
  [ "$(grep -c '^problem: openbao: other_[a-z_]*: no row of the table names it, and no rule records it$' <<<"$found")" -gt 10 ]
  # One more expression that selects by a regular expression on __name__ than the table pins.
  jq -c 'if .name == "cloudnative-pg" then .model.panels += [{"type": "stat", "datasource": {"type": "prometheus", "uid": "Prometheus"},
    "targets": [{"expr": "{__name__=~\"cnpg_.*\"}"}]}] else . end' "$KEPT" >"$mutant-name.jsonl"
  found="$(scraped "$mutant-name.jsonl" "$TABLE" "$MONITORS" "$RULES" | grep '^problem: ')"
  echo "$found"
  [ "$found" = "problem: cloudnative-pg: 5 expressions name a metric by __name__, and the table pins unread:4" ]
  # And any in a dashboard written for this tree.
  jq -c 'if .name == "flux" then .model.panels[0].targets += [{"expr": "{__name__=~\"flux_.*\"}"}] else . end' "$KEPT" >"$mutant-own.jsonl"
  found="$(scraped "$mutant-own.jsonl" "$TABLE" "$MONITORS" "$RULES" | grep '^problem: ')"
  echo "$found"
  [ "$found" = "problem: flux: 1 expressions name a metric by __name__, which a dashboard written for this tree may not" ]
}

@test "A dashboard maps each input it declares to a datasource of the type the input declares" {
  local problems declared
  datasources
  all_boards
  echo "datasources of the tree: $DATASOURCES"
  # shellcheck disable=SC2016 # jq variables.
  problems="$(jq -r --argjson datasources "$DATASOURCES" '
    .name as $name | (try (.json | fromjson) catch {}) as $model
    | [($model.__inputs // [])[] | select(.type == "datasource")] as $inputs
    | ([.datasources[].inputName] | sort) as $mapped | ([$inputs[].name] | sort) as $declared
    | (if $mapped != $declared then "\($name): maps the inputs \($mapped | join(", ")), and its JSON declares \($declared | join(", "))" else empty end),
      (.datasources[] | . as $map | ([$inputs[] | select(.name == $map.inputName)] | first) as $input
        | select($input != null)
        | if $input.pluginId == "__expr__"
          # The expression datasource is Grafana itself, by the uid __expr__ (DatasourceUID in pkg/expr/service.go of
          # Grafana v13.1.3), which is what the operator writes in the place of the input.
          then (if $map.datasourceName == "__expr__" then empty else "\($name): maps \($map.inputName), an expression input, to \($map.datasourceName), not to __expr__" end)
          elif any($datasources[]; .name == $map.datasourceName and .type == $input.pluginId) then empty
          else "\($name): maps \($map.inputName), an input for \($input.pluginId), to \($map.datasourceName), which is no \($input.pluginId) datasource of the tree" end)' "$BOARDS")"
  echo "problems: ${problems:-none}"
  [ -z "$problems" ]
  declared="$(jq -r '.name as $name | (try (.json | fromjson) catch {}) | (.__inputs // [])[] | select(.type == "datasource") | "\($name): \(.name) (\(.pluginId))"' "$BOARDS")"
  echo "inputs declared: $(paste -sd';' - <<<"$declared")"
  # Some dashboard declares one: the check is not vacuous.
  [ "$(grep -c . <<<"$declared")" -ge 2 ]
}

@test "A dashboard written for this tree reads its series by names and jobs the cluster gives" {
  local name given problems matched quoted
  # What the check reads of a job matcher, on a literal expression: its operator and its value, in
  # each of PromQL's quotes.
  # shellcheck disable=SC2016 # The backticks are a PromQL quote, not a command.
  [ "$(jq -R -r "$DASHBOARDS_JQ"'job_matchers[] | join(" ")' <<<'a{job="x"} + b{job='\''y'\''} + c{job=`z`} + d{exported_job="w", job=~"v.*"}' | paste -sd';' -)" = "= x;= y;= z;=~ v.*" ]
  # With comments inside the braces, which PromQL admits there, and none read from a comment.
  [ "$(jq -R -s -r "$DASHBOARDS_JQ"'job_matchers[] | join(" ")' <<<$'a{job # the job\n= # its value\n"x"} # b{job="y"}\n+ c{d="job=\\"z\\"", job="w"}' | paste -sd';' -)" = '= x;= w' ]
  # How many labels and metrics are named in quotes, in any of PromQL's quotes and escapes; none in a
  # string or a comment counts.
  # shellcheck disable=SC2016 # The backticks are a PromQL quote, not a command.
  [ "$(jq -R -s -r "$DASHBOARDS_JQ"'quoted_names' <<<$'a{"job"="x"} + b{c="d", \'e\'!~"f", `g`=~"h"} + {"i.j"} + k{"l\\x6fb"="m"} + n{o="{\\"p\\"=q}"} # {"r"="s"}\n+ t{job="u"}')" = 5 ]
  pinned_apps
  kept
  given="$(jobs)"
  echo "jobs the monitors of the render give: $given"
  [ "$(jq 'length' <<<"$given")" -gt 20 ]
  for name in $OWN_DASHBOARDS; do
    [ "$(NAME="$name" jq -c 'select(.name == env.NAME and .app != "grafana")' "$KEPT" | grep -c .)" -eq 1 ] || { echo "$name: no application delivers it"; return 1; }
  done
  problems="$(own_problems "$KEPT" "$given")"
  echo "problems: ${problems:-none}"
  [ -z "$problems" ]
  # The dashboards do match jobs, four of them: the check is not vacuous.
  # shellcheck disable=SC2016 # jq variables.
  matched="$(jq -r --arg own "$OWN_DASHBOARDS" "$DASHBOARDS_JQ"'
    select(.name as $name | $own | split(" ") | index($name) != null)
    | .model | queries([]) | (.exprs[], .variables[]) | .text | strings
    | job_matchers[] | select(.[0] == "=") | .[1]' "$KEPT" | sort -u | paste -sd' ' -)"
  echo "jobs the dashboards match: $matched"
  [ "$(wc -w <<<"$matched")" -ge 4 ]

  # The check's own proof, on a copy: a job no monitor gives, in each of PromQL's quotes, is named.
  # shellcheck disable=SC2016 # The backticks are a PromQL quote, not a command.
  for quoted in '"cilium-agents"' "'cilium-agents'" '`cilium-agents`'; do
    QUOTED="$quoted" jq -c 'if .name == "cilium-bgp" then .model.panels[0].targets[0].expr = "count(up{job=\(env.QUOTED)} == 1)" else . end' "$KEPT" >"$BATS_TEST_TMPDIR/mutant-job.jsonl"
    problems="$(own_problems "$BATS_TEST_TMPDIR/mutant-job.jsonl" "$given")"
    echo "with job=$quoted: ${problems:-none}"
    [ "$problems" = "cilium-bgp: panel 1 matches the job cilium-agents, which no monitor of the render gives" ]
  done
  # And with a comment between the label and its value, which PromQL admits inside braces.
  jq -c 'if .name == "cilium-bgp" then .model.panels[0].targets[0].expr = "count(up{job # the agents\n= \"cilium-agents\"} == 1)" else . end' "$KEPT" >"$BATS_TEST_TMPDIR/mutant-job.jsonl"
  problems="$(own_problems "$BATS_TEST_TMPDIR/mutant-job.jsonl" "$given")"
  echo "with a comment inside the matcher: ${problems:-none}"
  [ "$problems" = "cilium-bgp: panel 1 matches the job cilium-agents, which no monitor of the render gives" ]
  # A label named in quotes, which Prometheus 3 admits with any of PromQL's quotes and escapes, is
  # refused, whatever it names.
  # shellcheck disable=SC2016 # The backticks are a PromQL quote, not a command.
  for quoted in '"job"' "'job'" '`job`' '"j\x6fb"'; do
    QUOTED="$quoted" jq -c 'if .name == "cilium-bgp" then .model.panels[0].targets[0].expr = "count(up{\(env.QUOTED)=\"cilium-agents\"} == 1)" else . end' "$KEPT" >"$BATS_TEST_TMPDIR/mutant-job.jsonl"
    problems="$(own_problems "$BATS_TEST_TMPDIR/mutant-job.jsonl" "$given")"
    echo "with the label $quoted: ${problems:-none}"
    [ "$problems" = "cilium-bgp: panel 1 names a metric or a label in quotes, which a dashboard written for this tree may not" ]
  done
  # A variable but the one for the datasource, of any type: Grafana puts a constant's text in a query as
  # it is, so up{$sel} may match a job the check does not read, and adds an ad hoc filter to every query
  # of its datasource, so up{job="cilium-agent"} runs with the filter's job beside its own.
  # shellcheck disable=SC2016 # Grafana's variables.
  jq -c 'if .name == "cilium-bgp" then (.model.templating.list += [{"type": "constant", "name": "sel", "query": "job=\"cilium-agents\"", "hide": 2}]
    | .model.panels[0].targets[0].expr = "count(up{$sel} == 1) or vector(0)") else . end' "$KEPT" >"$BATS_TEST_TMPDIR/mutant-variable.jsonl"
  problems="$(own_problems "$BATS_TEST_TMPDIR/mutant-variable.jsonl" "$given")"
  echo "with a constant: ${problems:-none}"
  [ "$problems" = "cilium-bgp: it defines the variable sel, of type constant, and may define none but its datasource" ]
  # shellcheck disable=SC2016 # Grafana's variables.
  jq -c 'if .name == "cilium-bgp" then .model.templating.list += [{"type": "adhoc", "name": "filters", "datasource": {"type": "prometheus", "uid": "${datasource}"},
    "filters": [{"key": "job", "operator": "=", "value": "cilium-agents"}]}] else . end' "$KEPT" >"$BATS_TEST_TMPDIR/mutant-variable.jsonl"
  problems="$(own_problems "$BATS_TEST_TMPDIR/mutant-variable.jsonl" "$given")"
  echo "with an ad hoc filter: ${problems:-none}"
  [ "$problems" = "cilium-bgp: it defines the variable filters, of type adhoc, and may define none but its datasource" ]
  for type in custom query textbox interval; do
    TYPE="$type" jq -c 'if .name == "cilium-bgp" then .model.templating.list += [{"type": env.TYPE, "name": "v", "query": "x"}] else . end' "$KEPT" >"$BATS_TEST_TMPDIR/mutant-variable.jsonl"
    problems="$(own_problems "$BATS_TEST_TMPDIR/mutant-variable.jsonl" "$given")"
    echo "with a variable of type $type: ${problems:-none}"
    [ "$problems" = "cilium-bgp: it defines the variable v, of type $type, and may define none but its datasource" ]
  done
}

@test "The Cilium agents' series carry the label the Cilium dashboard selects them by" {
  local monitor daemonset copied label value matchers
  cluster_render
  monitor="$CLUSTER_RENDER/cilium-monitoring/PodMonitor.monitoring.coreos.com_kube-system_cilium-agent.yaml"
  daemonset="$CLUSTER_RENDER/cilium/DaemonSet.apps_kube-system_cilium.yaml"
  [ -f "$monitor" ]
  [ -f "$daemonset" ]
  # The monitor selects the agents' pods and copies one of their labels onto every series.
  jq -e --argjson labels "$(yq -o json -I0 '.spec.template.metadata.labels' "$daemonset")" 'to_entries | length > 0 and all(. as $e | $labels[$e.key] == $e.value)' \
    <<<"$(yq -o json -I0 '.spec.selector.matchLabels' "$monitor")"
  copied="$(yq '.spec.podTargetLabels // [] | .[]' "$monitor")"
  echo "pod labels the monitor copies: ${copied:-none}"
  [ "$copied" = k8s-app ]
  # The series label is the pod label's name with every character outside letters, digits and _ made
  # an underscore (sanitizeLabelName and generatePodMonitorConfig in pkg/prometheus/promcfg.go of
  # prometheus-operator v0.95.2).
  label="${copied//[^a-zA-Z0-9_]/_}"
  value="$(yq '.spec.template.metadata.labels["k8s-app"] // ""' "$daemonset")"
  echo "the agents' series carry $label=\"$value\""
  [ -n "$value" ]
  # Every matcher of the dashboard on that label is for the value the pods carry, and there are
  # matchers on it: it is the label the dashboard selects the agents by.
  kept
  matchers="$(jq -r 'select(.name == "cilium-agent") | .model | [.. | objects | select(has("expr")) | .expr | strings] | .[]' "$KEPT" |
    grep -o -E '(^|[^A-Za-z0-9_])k8s_app[[:blank:]]*(=~|!~|!=|=)[[:blank:]]*"[^"]*"' | sed -E 's/^[^A-Za-z0-9_]//; s/[[:blank:]]//g' | sort | uniq -c)"
  echo "the dashboard's matchers on $label: $matchers"
  [ "$(awk '{ print $2 }' <<<"$matchers")" = "$label=\"$value\"" ]
  [ "$(awk '{ print $1 }' <<<"$matchers")" -ge 100 ]
}

@test "The documentation lists every dashboard and every scraped application that has none" {
  local running without missing monitored app name row count board folder described source file version licence
  pinned_apps
  kept
  cluster_render
  running="$(doc_table '| Dashboard | For | Describes | Source, revision, licence | Folder | Datasource |')"
  without="$(doc_table '| Application | Scraped by |')"
  missing="$(doc_table '| Component | Missing |')"
  echo "rows: $(grep -c . <<<"$running") of what runs, $(grep -c . <<<"$without") scraped without a dashboard, $(grep -c . <<<"$missing") missing a scrape or an upstream"
  [ -n "$running" ]
  [ -n "$without" ]
  [ -n "$missing" ]

  # Every dashboard an application delivers is one row of the first table, by the name of its
  # GrafanaDashboard in backticks, with its folder, the application it describes and where it comes
  # from; and the table names no dashboard the tree does not deliver.
  while IFS=$'\t' read -r board app folder; do
    row="$(awk -F'|' -v name="\`$board\`" 'index($2, name)' <<<"$running")"
    [ "$(grep -c . <<<"$row")" -eq 1 ] || { echo "$board: $(grep -c . <<<"$row") rows of the table of what runs name it"; return 1; }
    [ "$(cell 5 <<<"$row")" = "$folder" ] || { echo "$board: the table says the folder $(cell 5 <<<"$row"), and it is in $folder"; return 1; }
    if [ "$app" != grafana ]; then
      described="${app%-dashboard}"
      [[ " $(cell 3 <<<"$row" | backticked | xargs) " == *" $described "* ]] || { echo "$board: the table does not say it describes $described"; return 1; }
    fi
    # Where it comes from is what the tree holds: written here, under the tree's licence, or an
    # upstream file at the revision and under the licence its record gives.
    source="$(cell 4 <<<"$row")"
    if [ "$app" = grafana ] || [[ " $OWN_DASHBOARDS " == *" $board "* ]]; then
      [ "$source" = "Written for this tree; Apache-2.0" ] || { echo "$board is written for this tree, and the table says: $source"; return 1; }
    else
      file="$(board_file "$app" "$board")"
      version="$(record "$file" "dashboard-[a-z0-9-]+")"
      licence="$(record "$file" Licence)"
      [ -n "$version" ]
      [ -n "$licence" ]
      [[ $source == *" at $version;"* || $source == *" at $version,"* ]] || { echo "$board: its record gives the revision $version, and the table says: $source"; return 1; }
      [[ $source == *"; $licence"* ]] || { echo "$board: its record gives the licence $licence, and the table says: $source"; return 1; }
    fi
  done < <(jq -r '[.name, .app, .folder] | @tsv' "$KEPT")
  [ "$(cell 1 <<<"$running" | backticked | sort | paste -sd' ' -)" = "$(jq -r .name "$KEPT" | sort | paste -sd' ' -)" ]

  # Every application whose render holds a monitor is named, in backticks, in exactly one of the
  # three tables: where a dashboard describes it, among those scraped without one, or among those
  # that miss an upstream; and the tables name no application without a monitor there.
  monitored="$(for app in "$CLUSTER_RENDER"/*/; do
    compgen -G "$app*Monitor.monitoring.coreos.com_*.yaml" >/dev/null && basename "$app"
  done | sort)"
  echo "applications with a monitor: $(paste -sd' ' - <<<"$monitored")"
  [ "$(grep -c . <<<"$monitored")" -gt 20 ]
  for app in $monitored; do
    count=0
    grep -qxF "$app" <<<"$(cell 3 <<<"$running" | backticked)" && count=$((count + 1))
    grep -qxF "$app" <<<"$(cell 1 <<<"$without" | backticked)" && count=$((count + 1))
    grep -qxF "$app" <<<"$(cell 1 <<<"$missing" | backticked)" && count=$((count + 1))
    [ "$count" -eq 1 ] || { echo "$app, which has a monitor, is named in $count of the three tables"; return 1; }
  done
  for name in $( { cell 3 <<<"$running"; cell 1 <<<"$without"; cell 1 <<<"$missing"; } | backticked | sort -u); do
    grep -qxF "$name" <<<"$monitored" || { echo "the tables name $name, which has no monitor in the render"; return 1; }
  done
}
