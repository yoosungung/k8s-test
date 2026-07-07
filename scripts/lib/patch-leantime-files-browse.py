#!/usr/bin/env python3
"""Apply k8s-test /files/browse memory fix to vendored Leantime blade patches."""
from __future__ import annotations

import pathlib
import re
import sys

INCLUDE_RE = re.compile(
    r"@include\('menu::partials\.(\w+)',\s*(\[[^\]]*\])\)"
)


def isolated_view(partial: str, args: str) -> str:
    return "{!! view('menu::partials.%s', %s)->render() !!}" % (partial, args)


PARTIAL_EXTRA: dict[str, str] = {
    "projectListFilter": ", 'projectSelectGroupOptions' => $projectSelectGroupOptions",
    "projectGroup": ", 'projectTypeAvatars' => $projectTypeAvatars",
    "noGroup": ", 'projectTypeAvatars' => $projectTypeAvatars",
    "clientGroup": ", 'projectTypeAvatars' => $projectTypeAvatars",
}


def with_extra(partial: str, args: str) -> str:
    extra = PARTIAL_EXTRA.get(partial, "")
    if extra and extra.strip(", ") not in args:
        return args[:-1] + extra + "]"
    return args


def patch_project_group(text: str) -> str:
    text = text.replace(
        "@include('menu::partials.projectLink')",
        isolated_view(
            "projectLink",
            "['project' => $project, 'projectTypeAvatars' => $projectTypeAvatars ?? []]",
        ),
    )
    text = text.replace(
        "@include('menu::partials.projectGroup', ['projects' => $project['children'], "
        "'parent' => $project['id'], 'level'=> $level+1, 'prefix' => $prefix, "
        '"currentProject"=>$currentProject])',
        isolated_view(
            "projectGroup",
            "['projects' => $project['children'], 'parent' => $project['id'], "
            "'level'=> $level+1, 'prefix' => $prefix, 'currentProject'=> $currentProject, "
            "'projectTypeAvatars' => $projectTypeAvatars ?? []]",
        ),
    )
    return INCLUDE_RE.sub(
        lambda m: isolated_view(m.group(1), with_extra(m.group(1), m.group(2))), text
    )


def patch_no_group(text: str) -> str:
    return text.replace(
        "@include('menu::partials.projectLink')",
        isolated_view(
            "projectLink",
            "['project' => $project, 'projectTypeAvatars' => $projectTypeAvatars ?? []]",
        ),
    )


def patch_client_group(text: str) -> str:
    return text.replace(
        "@include('menu::partials.projectLink')",
        isolated_view(
            "projectLink",
            "['project' => $project, 'projectTypeAvatars' => $projectTypeAvatars ?? []]",
        ),
    )


def patch_wrapper_project_selector(text: str) -> str:
    header = "{{-- k8s-test patch: isolated view() renders avoid get_defined_vars OOM on /files/browse --}}\n"
    if not text.startswith("{{-- k8s-test patch"):
        text = header + text
    replacement = """{!! view('menu::partials.projectSelector', [
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
])->render() !!}"""
    return text.replace("@include('menu::partials.projectSelector', [])", replacement)


def patch_head_menu(text: str) -> str:
    text = text.replace(
        "@include('menu::projectSelector')",
        "{!! view('menu::projectSelector', ['menuType' => $menuType])->render() !!}",
    )
    text = text.replace(
        "@include('timesheets::partials.stopwatch', [\n               'onTheClock' => $onTheClock\n           ])",
        "{!! view('timesheets::partials.stopwatch', ['onTheClock' => $onTheClock])->render() !!}",
    )
    return text.replace(
        '@include("auth::partials.loginInfo")',
        "{!! view('auth::partials.loginInfo', ['user' => $user])->render() !!}",
    )


def patch_project_selector_partial(text: str) -> str:
    header = "{{-- k8s-test patch: isolated view() renders avoid get_defined_vars OOM on /files/browse --}}\n"
    if not text.startswith("{{-- k8s-test patch"):
        text = header + text
    return INCLUDE_RE.sub(
        lambda m: isolated_view(m.group(1), with_extra(m.group(1), m.group(2))), text
    )


def patch_menu(text: str) -> str:
    return text.replace(
        '@includeIf("menu::partials.leftnav.".$menuItem[\'type\'], ["menuItem" => $menuItem, "module" => $module, "action" => $action])',
        '@if(view()->exists("menu::partials.leftnav.".$menuItem[\'type\']))\n'
        '                    {!! view("menu::partials.leftnav.".$menuItem[\'type\'], ["menuItem" => $menuItem, "module" => $module, "action" => $action])->render() !!}\n'
        '                    @endif',
    )


def patch_app_layout(text: str) -> str:
    replacements = [
        ("@include('global::sections.header')", "{!! view('global::sections.header')->render() !!}"),
        ("@include('global::sections.appAnnouncement')", "{!! view('global::sections.appAnnouncement')->render() !!}"),
        ("@include('menu::headMenu')", "{!! view('menu::headMenu')->render() !!}"),
        ("@include('menu::menu')", "{!! view('menu::menu')->render() !!}"),
        ("@include('global::sections.footer')", "{!! view('global::sections.footer')->render() !!}"),
        ("@include('global::sections.pageBottom')", "{!! view('global::sections.pageBottom')->render() !!}"),
        ("@include('help::helpermodal')", "{!! view('help::helpermodal')->render() !!}"),
    ]
    for old, new in replacements:
        text = text.replace(old, new)
    return text


def patch_browse(text: str) -> str:
    header = "{{-- k8s-test patch: removed $module/$action — they triggered layout @include recursion OOM on /files/browse --}}\n"
    if not text.startswith("{{-- k8s-test patch"):
        text = header + text
    return text.replace(
        "    use Leantime\\Core\\Controller\\Frontcontroller;\n"
        "    $module = 'project';\n"
        "    $action = Frontcontroller::getActionName('');\n",
        "",
    )


def patch_show_all(text: str) -> str:
    return text.replace(
        "action='{{ BASE_URL }}/files/showAll@if(isset($_GET['modalPopUp']))?modalPopUp=true @endif'",
        "action='{{ BASE_URL }}/files/showAll{{ isset($_GET['modalPopUp']) ? '?modalPopUp=true' : '' }}'",
    )


def main() -> None:
    patch_root = pathlib.Path(sys.argv[1])
    handlers = {
        patch_root / "app/Domain/Menu/Templates/partials/projectSelector.blade.php": patch_project_selector_partial,
        patch_root / "app/Domain/Menu/Templates/partials/projectGroup.blade.php": patch_project_group,
        patch_root / "app/Domain/Menu/Templates/partials/noGroup.blade.php": patch_no_group,
        patch_root / "app/Domain/Menu/Templates/partials/clientGroup.blade.php": patch_client_group,
        patch_root / "app/Domain/Menu/Templates/projectSelector.blade.php": patch_wrapper_project_selector,
        patch_root / "app/Domain/Menu/Templates/headMenu.blade.php": patch_head_menu,
        patch_root / "app/Domain/Menu/Templates/menu.blade.php": patch_menu,
        patch_root / "app/Views/Templates/layouts/app.blade.php": patch_app_layout,
        patch_root / "app/Domain/Files/Templates/browse.blade.php": patch_browse,
        patch_root / "app/Domain/Files/Templates/showAll.blade.php": patch_show_all,
    }
    for path, fn in handlers.items():
        if not path.exists():
            raise SystemExit(f"Missing {path}")
        path.write_text(fn(path.read_text()))


if __name__ == "__main__":
    main()
