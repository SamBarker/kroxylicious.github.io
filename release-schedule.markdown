---
layout: default
title: Release Schedule
permalink: /release-schedule/
---

<div class="container-xxl krx-gutter py-5">
  <div class="row">
    <div class="col">
      <h1>Release Schedule</h1>
      <p>This page documents the planned and released versions of Kroxylicious.</p>

      <div class="table-responsive mt-4">
        <table class="table table-striped table-hover">
          <thead>
            <tr>
              <th scope="col">Release</th>
              <th scope="col">Planned Release Date</th>
              <th scope="col">Milestone</th>
              <th scope="col">Project Board</th>
              <th scope="col">Status</th>
            </tr>
          </thead>
          <tbody>
            {%- for release in site.data.release-schedule.releases -%}
            {%- assign underscored_version = release.version | replace: '.', '_' -%}
            <tr>
              <td>Kroxylicious {{ release.version }}</td>
              <td>
                {{ release.plannedDate }}
                {%- if release.oldDate %} <span class="text-muted">(was {{ release.oldDate }})</span>{% endif -%}
              </td>
              <td><a href="https://github.com/kroxylicious/kroxylicious/milestone/{{ release.milestoneNumber }}">{{ release.version }}</a></td>
              <td>
                {%- if release.projectNumber -%}
                <a href="https://github.com/orgs/kroxylicious/projects/{{ release.projectNumber }}">{{ release.version }}</a>
                {%- else -%}
                -
                {%- endif -%}
              </td>
              <td>
                {%- if site.data.release[underscored_version] -%}
                <span class="badge bg-success">Released</span>
                {%- else -%}
                <span class="badge bg-info">Planned</span>
                {%- endif -%}
              </td>
            </tr>
            {%- endfor -%}
          </tbody>
        </table>
      </div>
    </div>
  </div>
</div>

<div class="container-xxl krx-gutter py-5">
  <div class="row">
    <div class="col">
      <h2>Backports, CVEs, and respins, oh my!</h2>
      <div class="alert alert-warning" role="alert">
        <strong>Found an undisclosed vulnerability?</strong> Please follow our <a href="https://github.com/kroxylicious/kroxylicious/security/policy">security disclosure policy</a> rather than raising it publicly. The process below is for backporting CVEs that are already public.
      </div>
      <p>Kroxylicious is a community endeavour: we maintain one branch, <code>main</code>, and make releases from it.
      We always recommend running the latest release.</p>
      <p>We recognise this doesn't work for everyone. The community can get fixes into older releases — with a little help from a friend.</p>

      <p>A note on <strong>respins</strong>: a CVE in a base image alone is not a reason to cut a maintenance release — rebuild your container image instead.
      Maintenance releases are for vulnerabilities in Kroxylicious code or its runtime dependencies.</p>

      <h3>How to get a maintenance release</h3>
      <ol>
        <li><strong>Start a conversation</strong> — anyone in the community, including committers and project managers, needs to drop a note to <a href="mailto:kroxylicious-dev@googlegroups.com">kroxylicious-dev@googlegroups.com</a> describing the version you need and the fixes required.
        This is a discussion, not a demand: you'll need to convince a committer that a maintenance release makes sense.</li>
        <li><strong>A committer creates the release branch</strong> — if a committer agrees, they will create a <code>release/X.Y</code> branch.
        Community members cannot create release branches directly; this step requires a committer.</li>
        <li><strong>The community does the work</strong> — cherry-picks from <code>main</code> are ideal, but not always practical.
        Were <code>main</code> ever to move to a new major version of a core dependency, an older release on the previous version would need changes adapted rather than simply cherry-picked.
        The contributor proposing the backport is responsible for that adaptation.</li>
        <li><strong>Agree scope</strong> — before cutting the maintenance release, the committer should call for lazy consensus on the mailing list: share what will be included and allow a reasonable window for objections.
        There's no value in running the release machinery for every individual change; batching is preferred.
        For a highly exploitable CVE the committers may agree to shorten or waive the consensus window.</li>
        <li><strong>A committer cuts the release</strong> — once consensus is reached, lazy style, on the branch content, a committer will cut the release.</li>
      </ol>
    </div>
  </div>
</div>
