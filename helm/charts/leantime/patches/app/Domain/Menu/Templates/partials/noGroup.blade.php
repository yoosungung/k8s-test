<ul class="level-0 noGroup">
    @foreach($projects as $project)

        @if(
           !session()->exists("usersettings.projectSelectFilter.client")
            || session("usersettings.projectSelectFilter.client") == $project["clientId"]
            || session("usersettings.projectSelectFilter.client") == 0
            || session("usersettings.projectSelectFilter.client") == ""
           )

            <li class="projectLineItem hasSubtitle {{ session("currentProject") ?? 0  == $project['id'] ? "active" : '' }}" >
                {!! view('menu::partials.projectLink', ['project' => $project, 'projectTypeAvatars' => $projectTypeAvatars ?? []])->render() !!}
                <div class="clear"></div>
            </li>

        @endif

    @endforeach
</ul>
