<?php
/**
 * Probe view render memory for projectSelector under different page var sets.
 */
declare(strict_types=1);

define('RESTRICTED', true);
define('LEANTIME_START', microtime(true));

$root = getenv('LEANTIME_ROOT') ?: '/var/www/html';
require "{$root}/vendor/autoload.php";

$app = require "{$root}/bootstrap/app.php";
$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();

/** @var \Leantime\Core\UI\Template $tpl */
$tpl = $app->make(\Leantime\Core\UI\Template::class);
$tpl->setupGlobalVars();

/** @var \Leantime\Domain\Auth\Services\Auth $auth */
$auth = $app->make(\Leantime\Domain\Auth\Services\Auth::class);
/** @var \Leantime\Domain\Auth\Repositories\Auth $authRepo */
$authRepo = $app->make(\Leantime\Domain\Auth\Repositories\Auth::class);
$user = $authRepo->getUserByEmail('dulle2@gmail.com');
if (! $user) {
    fwrite(STDERR, "user not found\n");
    exit(1);
}
$auth->setUserSession($user);
session([
    'currentProject' => 9,
    'currentProjectName' => 'My Project',
    'menuType' => 'project',
    'usersettings' => array_merge(session('usersettings', []), [
        'projectSelectFilter' => ['groupBy' => 'structure', 'client' => null],
    ]),
]);

$files = $app->make(\Leantime\Domain\Files\Services\Files::class);

$scenarios = [
    'minimal' => [],
    'kanban-like' => ['tickets' => [], 'milestones' => []],
    'browse-like' => [
        'currentModule' => 9,
        'modules' => $files->getModules(1),
        'imgExtensions' => $files->getImageExtensions(),
        'files' => $files->getFilesByModule('project', 9),
    ],
];

foreach ($scenarios as $name => $vars) {
    foreach ($vars as $k => $v) {
        $tpl->assign($k, $v);
    }

    $mem0 = memory_get_usage(true);
    try {
        $html = view('menu::projectSelector')->render();
        $peak = memory_get_peak_usage(true);
        printf("%s ok bytes=%d peak=%.1fMiB delta=%.1fMiB\n",
            $name,
            strlen($html),
            $peak / 1024 / 1024,
            ($peak - $mem0) / 1024 / 1024
        );
    } catch (Throwable $e) {
        $peak = memory_get_peak_usage(true);
        printf("%s FAIL peak=%.1fMiB err=%s\n", $name, $peak / 1024 / 1024, $e->getMessage());
    }
    // reset template vars between scenarios
    foreach (array_keys($vars) as $k) {
        $tpl->assign($k, null);
    }
}
