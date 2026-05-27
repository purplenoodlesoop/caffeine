{
  name = "ci";
  # YAML's `on:` would otherwise serialize as a boolean key; the YAML formatter
  # quotes it so this stays a string.
  on = {
    push.branches = [ "master" ];
    pull_request = { };
    # Allow manual re-runs from the Actions UI or `gh workflow run ci.yml`.
    workflow_dispatch = { };
  };
  concurrency = {
    group = "ci-\${{ github.ref }}";
    cancel-in-progress = true;
  };
  jobs.flake-check = {
    name = "nix flake check";
    runs-on = "ubuntu-latest";
    timeout-minutes = 30;
    permissions.contents = "read";
    steps = [
      {
        name = "Checkout";
        uses = "actions/checkout@v4";
      }
      {
        name = "Install Nix";
        uses = "DeterminateSystems/nix-installer-action@v22";
        "with".determinate = false;
      }
      {
        name = "Magic Nix Cache";
        uses = "DeterminateSystems/magic-nix-cache-action@v13";
      }
      {
        name = "Flake check";
        run = "nix flake check --print-build-logs";
      }
    ];
  };
}
