<!DOCTYPE html>
<html dir="{{ __('language.direction') }}" lang="{{ __('language.code') }}">
<head>
    {!! view('global::sections.header')->render() !!}
    @stack('styles')
</head>

<body class="" hx-ext="preload" hx-headers='{"X-CSRF-TOKEN": "{{ csrf_token() }}"}'>

    {!! view('global::sections.appAnnouncement')->render() !!}

    <div class="mainwrapper menu{{ session("menuState") ?? "closed" }}">

        <div class="header">

            <div class="headerinner">
                <a class="btnmenu" href="javascript:void(0);"></a>

                <a class="barmenu" href="javascript:void(0);">
                    <span class="fa fa-bars"></span>
                </a>

                <div class="logo">
                    <a
                        href="{{ BASE_URL }}"
                        style="background-image: url('{{ BASE_URL }}/dist/images/logo.svg')"
                    >&nbsp;</a>
                </div>

                {!! view('menu::headMenu')->render() !!}
            </div><!-- headerinner -->

        </div><!-- header -->



        <div class="overlay" style="position: relative">
            <div class="leftpanel">
                <div class="leftmenu">
                    {!! view('menu::menu')->render() !!}
                </div><!-- leftmenu -->
            </div>
            <div class="rightpanel {{ $section }}">
                <div class="primaryContent">
                    @isset($action, $module)
                        @include("$module::$action")
                    @else
                        @yield('content')
                    @endisset
                    <div class="clearfix"></div>
                    {!! view('global::sections.footer')->render() !!}
                </div>

            </div>

        </div><!-- rightpanel -->

        <div class="menu-backdrop" aria-hidden="true"></div>

    </div><!-- mainwrapper -->

    {!! view('global::sections.pageBottom')->render() !!}
    @stack('scripts')
    {!! view('help::helpermodal')->render() !!}
</body>

</html>
