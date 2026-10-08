# Prints each entry of local.dns_records in tofu/dns-records.tf as one line:
# its key, a tab, and its body squeezed onto one line. Comparing two
# versions' output says which records a change touched.
/^  dns_records = \{/ { inside = 1; next }
inside && /^  \}/ { inside = 0 }
inside && match($0, /^    "[^"]+" = \{/) {
  key = $0
  sub(/^    "/, "", key)
  sub(/" = \{.*/, "", key)
  body = ""
  next
}
inside && key != "" && /^    \}/ { print key "\t" body; key = ""; next }
inside && key != "" { gsub(/^ +| +$/, ""); body = body " " $0 }
