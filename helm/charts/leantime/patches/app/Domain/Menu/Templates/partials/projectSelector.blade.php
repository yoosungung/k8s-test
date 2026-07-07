{{-- k8s-test patch: isolated view() renders avoid get_defined_vars OOM on /files/browse --}}
@props([
    'redirect' => 'dashboard/show',
    'currentProject'
])

<div class="dropdown-menu projectselector" id="mainProjectSelector">

        @if ($menuType == 'project' || $menuType == 'default')
            <div class="head">
                <span class="sub">{{ __("menu.current_project") }}</span><br />
                <span class="title">{{ session("currentProjectName") }}</span>
            </div>
        @else
            <div class="projectSelectorFooter" style="border:none; border-bottom:1px solid var(--main-border-color)">
            <ul class="selectorList projectList">
                <li>
                    <a href="{{ BASE_URL }}/projects/showMy"><strong><i class="fa-solid fa-house-flag"></i> Open Project Hub</strong></a>
                </li>

                @if ($login::userIsAtLeast("manager"))
                    @dispatchEvent('beforeProjectCreateLink')
                    <li><a href="{{ $startSomethingUrl }}">
                            <span class="fancyLink">
                                {!! __('menu.create_something_new') !!}
                            </span>
                        </a>
                    </li>
                    @dispatchEvent('afterProjectCreateLink')
                @endif

            </ul>
            </div>
        @endif


    <div class="tabbedwidget tab-primary projectSelectorTabs">
        <ul class="tabs">
            <li><a href="#myProjects">{{ __('menu.projectselector.my_projects') }}</a></li>
            <li><a href="#favorites">{{ __('menu.projectselector.favorites') }}</a></li>
            <li><a href="#recentProjects">{{ __('menu.projectselector.recent') }}</a></li>
            <li><a href="#allProjects">{{ __('menu.projectselector.all_projects') }}</a></li>
        </ul>

        <div id="myProjects" class="scrollingTab">
            {!! view('menu::partials.projectListFilter', ['clients' => $clients, 'projectSelectFilter' => $projectSelectFilter, 'projectSelectGroupOptions' => $projectSelectGroupOptions])->render() !!}
            <ul class="selectorList projectList htmx-loaded-content">
                @if($projectSelectFilter["groupBy"] == "client")
                    {!! view('menu::partials.clientGroup', ['projects' => $allAssignedProjects, 'parent' => 0, 'level'=> 0, "prefix" => "myClientProjects", "currentProject"=>$currentProject, 'projectTypeAvatars' => $projectTypeAvatars])->render() !!}
                @elseif($projectSelectFilter["groupBy"] == "structure")
                    {!! view('menu::partials.projectGroup', ['projects' => $projectHierarchy, 'parent' => 0, 'level'=> 0, "prefix" => "myProjects", "currentProject"=>$currentProject, 'projectTypeAvatars' => $projectTypeAvatars])->render() !!}
                @else
                    {!! view('menu::partials.noGroup', ['projects' => $allAssignedProjects, "currentProject"=>$currentProject, 'projectTypeAvatars' => $projectTypeAvatars])->render() !!}
                @endif
            </ul>
        </div>
        <div id="allProjects" class="scrollingTab">
            {!! view('menu::partials.projectListFilter', ['clients' => $clients, 'projectSelectFilter' => $projectSelectFilter, 'projectSelectGroupOptions' => $projectSelectGroupOptions])->render() !!}
            <ul class="selectorList projectList htmx-loaded-content">
                @if($projectSelectFilter["groupBy"] == "client")
                    {!! view('menu::partials.clientGroup', ['projects' => $allAvailableProjects, 'parent' => 0, 'level'=> 0, "prefix" => "allClientProjects", "currentProject"=>$currentProject, 'projectTypeAvatars' => $projectTypeAvatars])->render() !!}
                @elseif($projectSelectFilter["groupBy"] == "structure")
                    {!! view('menu::partials.projectGroup', ['projects' => $allAvailableProjectsHierarchy, 'parent' => 0, 'level'=> 0, "prefix" => "allProjects", "currentProject"=>$currentProject, 'projectTypeAvatars' => $projectTypeAvatars])->render() !!}
                @else
                    {!! view('menu::partials.noGroup', ['projects' => $allAvailableProjects, "currentProject"=>$currentProject, 'projectTypeAvatars' => $projectTypeAvatars])->render() !!}
                @endif
            </ul>
        </div>
        <div id="recentProjects" class="scrollingTab">
            <ul class="selectorList projectList">
                @if(count($recentProjects) >= 1)
                    {!! view('menu::partials.noGroup', ['projects' => $recentProjects, 'projectTypeAvatars' => $projectTypeAvatars])->render() !!}
                @else
                    <li class='nav-header'></li>
                    <li><span class='info'>
                        {{ __("menu.you_dont_have_projects") }}
                        </span>
                    </li>
                @endif
            </ul>
        </div>
        <div id="favorites" class="scrollingTab">
            <ul class="selectorList projectList">
                @if(count($favoriteProjects) >= 1)
                    {!! view('menu::partials.noGroup', ['projects' => $favoriteProjects, 'projectTypeAvatars' => $projectTypeAvatars])->render() !!}
                @else
                    <li><span class='info'>
                        {{ __("text.you_have_not_favorited_any_projects") }}
                        </span>
                    </li>
                @endif
            </ul>
        </div>
    </div>

            @if ($menuType == 'project' || $menuType == 'default')
        <div class="projectSelectorFooter">
            <ul class="selectorList projectList">

                @if ($login::userIsAtLeast("manager"))
                    @dispatchEvent('beforeProjectCreateLink')
                    <li><a href="{{ $startSomethingUrl }}">
                            <span class="fancyLink">
                                {!! __('menu.create_something_new') !!}
                            </span>
                        </a>
                    </li>
                    @dispatchEvent('afterProjectCreateLink')
                @endif


                    <li>
                        <a href="{{ BASE_URL }}/projects/showMy"><i class="fa-solid fa-circle-nodes"></i> Project Hub</a>
                    </li>

            </ul>
        </div>

            @endif

</div>

<script>
    jQuery(document).ready(function () {
        leantime.menuController.initProjectSelector();
    });
</script>
