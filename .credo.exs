%{
  configs: [
    %{
      name: "default",
      strict: true,
      files: %{included: ["lib/", "test/", "config/", "scripts/"]},
      checks: [
        # This project's domain vocabulary IS "todo"; the tag check drowns in
        # false positives on docs and comments about the todos feature.
        {Credo.Check.Design.TagTODO, false}
      ]
    }
  ]
}
