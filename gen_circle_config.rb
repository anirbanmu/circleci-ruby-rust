# frozen_string_literal: true

require 'yaml'
require 'set'

class Version
  attr_reader :major, :minor, :patch

  def initialize(major, minor, patch, tag_with_major: false, tag_with_minor: false, tag_with_latest: false)
    @major = major
    @minor = minor
    @patch = patch
    @tag_with_major = tag_with_major
    @tag_with_minor = tag_with_minor
    @tag_with_patch = true
    @tag_with_latest = tag_with_latest
  end

  def full
    "#{major}.#{minor}.#{patch}"
  end

  def major_minor
    "#{major}.#{minor}"
  end

  def tag_with_major?
    @tag_with_major
  end

  def tag_with_minor?
    @tag_with_minor
  end

  def tag_with_patch?
    @tag_with_patch
  end

  def tag_with_latest?
    @tag_with_latest
  end
end

def sorted_categorized_versions(raw_versions_list)
  # Split into major, minor & patch versions. Sort descending.
  raw_versions_list = raw_versions_list.map { |v| v.split('.').map { |i| Integer(i) } }.sort.reverse
  tagged_latest_set = Set.new([raw_versions_list.first])

  # First categorize by major
  by_major = raw_versions_list.group_by { |v| v[0..0] }
  tagged_major_set = Set.new(by_major.values.map(&:first))

  # Then categorize by major.minor
  categorized = by_major.transform_values { |vs| vs.group_by { |v| v[0..1] } }
  tagged_minor_set = Set.new(categorized.values.flat_map { |minor_hash| minor_hash.values.map(&:first) })

  raw_versions_list.map do |v|
    Version.new(
      *v,
      tag_with_major: tagged_major_set.include?(v),
      tag_with_minor: tagged_minor_set.include?(v),
      tag_with_latest: tagged_latest_set.include?(v)
    )
  end
end

def generate_rb_rs_tags(rb_ver, rs_ver)
  ["rb#{rb_ver.full}-rs#{rs_ver.full}"].tap do |tags|
    if rb_ver.tag_with_minor?
      tags.push("rb#{rb_ver.major_minor}-rs#{rs_ver.full}")
    end
    if rs_ver.tag_with_minor?
      tags.push("rb#{rb_ver.full}-rs#{rs_ver.major_minor}")
    end
    if rb_ver.tag_with_minor? && rs_ver.tag_with_minor?
      tags.push("rb#{rb_ver.major_minor}-rs#{rs_ver.major_minor}")
    end

    tags.push('latest') if rb_ver.tag_with_latest? && rs_ver.tag_with_latest?
  end
end

IMAGE_NAME = 'anirbanmu/circleci-ruby-rust'

def generate_job_yaml(rb, rs, tags)
  build_command = [
    'sed "s/REPLACE_ME_WITH_RIGHT_CIRCLE_IMAGE/circleci\/ruby:' + rb.full + '/ "Dockerfile.template > Dockerfile',
    'docker build -t ' + tags.map { |t| "#{IMAGE_NAME}:#{t}" }.join(' -t ') + " --build-arg rust_version=\"#{rs.full}\" ."
  ].join("\n")

  publish_command = [
    'echo "$DOCKERHUB_ACCESS_TOKEN" | docker login -u "$DOCKERHUB_USERNAME" --password-stdin',
    *tags.map { |t| "docker push #{IMAGE_NAME}:#{t}" }
  ].join("\n")

  {
    'docker' => [{ 'image' => 'circleci/buildpack-deps' }],
    'steps' => [
      'checkout',
      'setup_remote_docker',
      {
        'run' => {
          'name' => 'Build Docker image',
          'command' => build_command
        }
      },
      {
        'run' => {
          'name' => 'Publish Docker image to Docker Hub',
          'command' => publish_command
        }
      }
    ]
  }
end

def job_name(rb, rs)
  "rb#{rb.full}-rs#{rs.full}"
end

def generate_circle_yaml(versions_path)
  versions = YAML.safe_load(File.read(versions_path))

  ruby_versions = sorted_categorized_versions(Set.new(versions.dig('versions', 'ruby')))
  rust_versions = sorted_categorized_versions(Set.new(versions.dig('versions', 'rust')))

  image_versions = ruby_versions.product(rust_versions)

  {
    'version' => 2,
    'jobs' => image_versions.map do |(rb, rs)|
      tags = generate_rb_rs_tags(rb, rs)
      name = job_name(rb, rs)
      [name, generate_job_yaml(rb, rs, tags)]
    end.to_h,
    'workflows' => {
      'version' => 2,
      'build-master' => {
        'jobs' => image_versions.map do |(rb, rs)|
          { job_name(rb, rs) => { 'filters' => { 'branches' => { 'only' => 'master' } } } }
        end
      }
    }
  }
end

yaml_hash = generate_circle_yaml(File.expand_path(File.join(__dir__, 'versions.yml')))
File.open(File.expand_path(File.join(__dir__, '.circleci', 'config.yml')), 'w') do |f|
  f.puts("# THIS IS A GENERATED FILE. DO NOT EDIT MANUALLY. EDIT ../versions.yml & RUN ../gen_circle_config.rb TO REGENERATE.\n")
  f.write(yaml_hash.to_yaml)
end
