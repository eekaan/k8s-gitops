# shellcheck shell=bash
# The render diff's pull request comment: its fixed text, and the grammar of everything else in it.
# scripts/render-diff writes the comment from these and checks what it wrote; scripts/ci-comment,
# which posts it in the bot's name, posts nothing else. A pull request's CI run, a fork's included,
# writes the comment, so outside a fenced diff it holds only the fixed text and application names
# and counts of a strict shape: no free text, where a mention, a reference, a link, an image or HTML
# would render.

render_comment_marker='<!-- k8s-gitops:render-diff -->'
render_comment_heading='### Render diff'
render_comment_unchanged='Nothing that Flux applies changes.'
render_comment_intro='What Flux would apply differently, per application:'
render_comment_table_head='| Application | Added | Removed | Changed |'
render_comment_table_rule='| --- | ---: | ---: | ---: |'
# GitHub refuses a longer comment body: "Body is too long (maximum is 65536 characters)".
render_comment_limit=65536
# The most render-diff writes, in bytes, which are never fewer than the characters GitHub counts:
# the comment job adds a line of its own.
render_comment_room=$((render_comment_limit - 512))
# shellcheck disable=SC2016 # Markdown code spans, not expansions.
render_comment_note='**The diff is truncated**: the whole of it does not fit in a comment, which holds 65536 characters. The smallest diffs are shown whole, the next is cut where the room ends, and the rest are left out; the table lists every application. `just render` of both commits and `just render-diff` show all of it.'
render_comment_footer='---
<sub>Rendered offline as Flux would apply each tree, charts expanded with the repository'"'"'s values
(<code>just render</code>, <code>just render-diff</code>). Each cluster'"'"'s
<code>cluster-config.example.yaml</code> and <code>cluster-secrets.example.yaml</code> stand in for its
own values. Secrets'"'"' data and the values a chart makes up anew on every render are never shown, so a
change to them does not show here.</sub>'

# render_comment_check FILE: succeeds when FILE is a comment render-diff could have written; says
# on stderr why not otherwise. Byte for byte: a regular file of at most render_comment_room bytes,
# without a NUL, which ends the text a shell or a C library reads, or a carriage return, which ends
# a line in Markdown though not here; the marker alone on its first line; then, line by line, the
# fixed text, table rows and section headings naming applications by their DNS labels, and diffs
# whose fence no line of theirs could close.
render_comment_check() {
  local file=$1 size
  if [[ ! -f $file || -L $file ]]; then
    echo "not a regular file" >&2
    return 1
  fi
  size=$(wc -c <"$file")
  if ((size > render_comment_room)); then
    echo "$size bytes, more than the $render_comment_room a comment may hold" >&2
    return 1
  fi
  # shellcheck disable=SC2094 # the file is only read, twice
  if ! tr -d '\000\r' <"$file" | cmp -s - "$file"; then
    echo "holds a NUL or a carriage return" >&2
    return 1
  fi
  if ! printf '%s\n' "$render_comment_marker" | cmp -s -n $((${#render_comment_marker} + 1)) - "$file"; then
    echo "its first line is not the marker" >&2
    return 1
  fi
  tail -n +2 "$file" | RC_HEADING=$render_comment_heading RC_UNCHANGED=$render_comment_unchanged \
    RC_INTRO=$render_comment_intro RC_HEAD=$render_comment_table_head RC_RULE=$render_comment_table_rule \
    RC_NOTE=$render_comment_note RC_FOOTER=$render_comment_footer LC_ALL=C awk '
    function fail(why) { printf "line %d: %s\n", NR + 1, why > "/dev/stderr"; failed = 1; exit 1 }
    BEGIN {
      app = "[a-z0-9]([-a-z0-9]*[a-z0-9])?/[a-z0-9]([-a-z0-9]*[a-z0-9])?"
      count = "(0|[1-9][0-9]*)"
      some = "[1-9][0-9]*"
      row = "^[|] `" app "` [|] " count " [|] " count " [|] " count " [|]$"
      summary = "^<summary><code>" app "</code>: " some " (added|removed|changed)(, " some " (removed|changed))?(, " some " changed)?</summary>$"
      footers = split(ENVIRON["RC_FOOTER"], footer, "\n")
      state = "heading"
    }
    state == "heading" { if ($0 != ENVIRON["RC_HEADING"]) fail("not the heading"); state = "blank-kind"; next }
    state == "blank-kind" { if ($0 != "") fail("not a blank line"); state = "kind"; next }
    state == "kind" {
      if ($0 == ENVIRON["RC_UNCHANGED"]) state = "blank-footer"
      else if ($0 == ENVIRON["RC_INTRO"]) state = "blank-table"
      else fail("neither the no-change line nor the table'"'"'s introduction")
      next
    }
    state == "blank-table" { if ($0 != "") fail("not a blank line"); state = "table-head"; next }
    state == "table-head" { if ($0 != ENVIRON["RC_HEAD"]) fail("not the table'"'"'s head"); state = "table-rule"; next }
    state == "table-rule" { if ($0 != ENVIRON["RC_RULE"]) fail("not the table'"'"'s rule"); state = "first-row"; next }
    state == "first-row" { if ($0 !~ row) fail("not a row of the table"); state = "rows"; next }
    state == "rows" {
      if ($0 == "") state = "next"
      else if ($0 !~ row) fail("not a row of the table")
      next
    }
    state == "next" {
      if ($0 == "<details>") state = "summary"
      else if ($0 == ENVIRON["RC_NOTE"]) state = "blank-footer"
      else if ($0 == footer[1]) { state = "footer"; at = 2; if (at > footers) state = "end" }
      else fail("not a section, the truncation note or the footer")
      next
    }
    state == "summary" { if ($0 !~ summary) fail("not a section'"'"'s summary"); state = "blank-fence"; next }
    state == "blank-fence" { if ($0 != "") fail("not a blank line"); state = "fence"; next }
    state == "fence" {
      if ($0 !~ /^```+diff$/) fail("not the opening fence of a diff")
      fence = substr($0, 1, length($0) - 4)
      state = "diff"
      next
    }
    state == "diff" {
      if ($0 == fence) state = "close"
      else if (index($0, fence)) fail("a line of the diff could close its fence")
      next
    }
    state == "close" { if ($0 != "</details>") fail("not the end of a section"); state = "blank-next"; next }
    state == "blank-next" { if ($0 != "") fail("not a blank line"); state = "next"; next }
    state == "blank-footer" { if ($0 != "") fail("not a blank line"); state = "footer"; at = 1; next }
    state == "footer" {
      if ($0 != footer[at]) fail("not the footer")
      if (++at > footers) state = "end"
      next
    }
    state == "end" { fail("text after the footer") }
    END {
      if (failed) exit 1
      if (state != "end") { printf "the comment ends before its footer\n" > "/dev/stderr"; exit 1 }
    }'
}
