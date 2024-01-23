---
layout: default
title: Use Cases
permalink: /use-cases/
---

<div class="row justify-content-center">
    <div class="col-11 col-lg-8 card shadow gx-5 gy-5 m-lg-5">
        <div class="card-body">
            <div class="card-title display-6 mx-2 mt-3 mb-4">Use Cases</div>
            <div class="row g-0">
                <div class="col-auto">
                  {% for use_case in site.use_cases %}
                    <h2>{{ use_case.name }}</h2>
                    <p>{{ use_case.content | markdownify }}</p>
                  {% endfor %}
                </div>
            </div>
        </div>
    </div>
</div>