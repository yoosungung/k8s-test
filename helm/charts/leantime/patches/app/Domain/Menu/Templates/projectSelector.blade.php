{{-- k8s-test patch: avoid @include get_defined_vars OOM on /files/browse --}}
<a href="{{ BASE_URL }}/projects/showMy"
   class="dropdown-toggle bigProjectSelector {{ $menuType == "project" ? "active" : "" }}"
   data-toggle="dropdown">

    @if ($menuType == 'project' || $menuType == 'default')
        <span class="projectAvatar {{ $currentProjectType }}">
        @if(isset($projectTypeAvatars[$currentProjectType]) && $projectTypeAvatars[$currentProjectType] != "avatar")
                <span class="{{ $projectTypeAvatars[$currentProjectType] }}"></span>
            @else
                <img src="{{ BASE_URL }}/api/projects?projectAvatar={{ $currentProject['id'] ?? -1 }}&v={{ format($currentProject['modified'] ?? '')->timestamp() }}"/>
            @endif
        </span>
        {{ $currentProject['name'] ?? "" }}&nbsp;

    @else
        {!! __('menu.projects') !!}
    @endif

   <i class="fa fa-caret-down" aria-hidden="true"></i>
</a>
{!! view('menu::partials.projectSelector', [
    'currentProject' => $currentProject,
    'redirect' => $redirectUrl ?? 'dashboard/show',
    'menuType' => $menuType,
    'clients' => $clients,
    'projectSelectFilter' => $projectSelectFilter,
    'projectSelectGroupOptions' => $projectSelectGroupOptions,
    'allAssignedProjects' => $allAssignedProjects,
    'projectHierarchy' => $projectHierarchy,
    'projectTypeAvatars' => $projectTypeAvatars,
    'allAvailableProjects' => $allAvailableProjects,
    'allAvailableProjectsHierarchy' => $allAvailableProjectsHierarchy,
    'recentProjects' => $recentProjects,
    'favoriteProjects' => $favoriteProjects,
    'startSomethingUrl' => $startSomethingUrl,
])->render() !!}
