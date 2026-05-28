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
  jobs = {
    # Job 1: read the matrix from the flake's `githubActions` output.
    matrix = {
      name = "matrix";
      runs-on = "ubuntu-latest";
      outputs.matrix = "\${{ steps.set-matrix.outputs.matrix }}";
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
          id = "set-matrix";
          name = "Generate matrix";
          run = ''
            set -Eeu
            matrix="$(nix eval --json '.#githubActions.matrix')"
            echo "matrix=$matrix" >> "$GITHUB_OUTPUT"
          '';
        }
      ];
    };

    # Job 2: one runner per flake check.
    check = {
      name = "\${{ matrix.name }}";
      needs = "matrix";
      runs-on = "\${{ matrix.os }}";
      timeout-minutes = 30;
      permissions.contents = "read";
      strategy = {
        fail-fast = false;
        matrix = "\${{ fromJSON(needs.matrix.outputs.matrix) }}";
      };
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
          name = "Build check";
          run = "nix build -L '.#\${{ matrix.attr }}'";
        }
      ];
    };
  };
}
