# rails-assets

## `gcr.io/paketo-buildpacks/rails-assets`

A Cloud Native Buildpack to precompile rails assets

## Packaging

To package this buildpack for consumption:

```bash
./scripts/package.sh --version 0.10.27
```

This will build the buildpack for all target architectures specified in `buildpack.toml` (amd64 and arm64 by default) and create a single archive containing binaries for all architectures in the `build/` directory.

## Publishing

To publish this buildpack to ECR:

```bash
./scripts/publish.sh \
  --image-ref 348674388966.dkr.ecr.us-east-1.amazonaws.com/neeto-deploy/paketo/buildpack/rails-assets:0.10.27
```

The script will automatically:
- Read target architectures from `buildpack.toml`
- Extract the buildpack archive
- Publish each architecture separately with arch-suffixed tags (e.g., `rails-assets:0.10.27-amd64`, `rails-assets:0.10.27-arm64`)
- Create and push a multi-arch manifest list

## Logging Configurations

To configure the level of log output from the **buildpack itself**, set the
`$BP_LOG_LEVEL` environment variable at build time either directly (ex. `pack
build my-app --env BP_LOG_LEVEL=DEBUG`) or through a [`project.toml`
file](https://github.com/buildpacks/spec/blob/main/extensions/project-descriptor.md)
If no value is set, the default value of `INFO` will be used.

The options for this setting are:
- `INFO`: (Default) log information about the progress of the build process
- `DEBUG`: log debugging information about the progress of the build process

```shell
$BP_LOG_LEVEL="DEBUG"
```

## Configuring Exta Assets Directories

By default, the `assets:precompile` command reads assets from a set of specific application paths, such as
`app/assets`, `app/javascript`, `lib/assets` and `vendor/assets`. These directories contain the
source files that need to be precompiled and optimized for production use. The precompiled assets
resulted from running this command are then placed in different directories, such
as `public/assets`, `public/packs` and `tmp/cache/assets`.

Any gem can override the behavior of the `assets:precompile` command, and use different directories
to either read source assets or write the precompilation results. It is possible to set a list of
additional source directories using the `$BP_RAILS_ASSETS_EXTRA_SOURCE_PATHS` environment variable.
In the same way, to set a list of additional destination paths, use `$BP_RAILS_ASSETS_EXTRA_DESTINATION_PATHS`.
Both variables have the same notation of the `$PATH` system variable.

```bash
# adds app/my_gem/assets and lib/other_gem/assets to
# the list of paths containing assets that need precompilation
BP_RAILS_ASSETS_EXTRA_SOURCE_PATHS="app/my_gem/assets:lib/other_gem/assets"

# adds public/my_gem and public/other_gem to
# the list of paths with assets resulting from the
# precompilation process
BP_RAILS_ASSETS_EXTRA_DESTINATION_PATHS="public/my_gem:public/other_gem"
```

Like the `$BP_LOG_LEVEL`, you can set those variables either directly with pack cli or using a `project.toml` file.
