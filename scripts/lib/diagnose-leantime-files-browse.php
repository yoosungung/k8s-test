<?php
/**
 * In-pod diagnostic: reproduce /files/browse render with memory tracing.
 * Usage (inside leantime container):
 *   php /tmp/diagnose-leantime-files-browse.php [route]
 * Default route: files/browse
 */
declare(strict_types=1);

define('RESTRICTED', true);
define('LEANTIME_START', microtime(true));

$root = getenv('LEANTIME_ROOT') ?: '/var/www/html';
require "{$root}/vendor/autoload.php";

use Leantime\Core\Http\IncomingRequest;

$route = $argv[1] ?? 'files/browse';
$route = ltrim($route, '/');

$app = require "{$root}/bootstrap/app.php";
$kernel = $app->make(Illuminate\Contracts\Console\Kernel::class);
$kernel->bootstrap();

echo "memory_limit=".ini_get('memory_limit')."\n";
echo "LEAN_DEBUG=".getenv('LEAN_DEBUG')."\n";
echo "route=/{$route}\n";

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
    'currentProjectClient' => 0,
    'menuType' => 'project',
]);

$memBefore = memory_get_usage(true);
echo 'mem_before='.round($memBefore / 1024 / 1024, 1)."MiB\n";

try {
    $request = IncomingRequest::create(
        '/'.$route,
        'GET',
        [],
        [],
        [],
        [
            'HTTP_HOST' => 'leantime.k8s-test',
            'HTTPS' => 'on',
            'SERVER_NAME' => 'leantime.k8s-test',
            'REQUEST_URI' => '/'.$route,
            'SCRIPT_NAME' => '/index.php',
        ]
    );
    $app->instance('request', $request);

    /** @var \Leantime\Core\Http\HttpKernel $httpKernel */
    $httpKernel = $app->make(\Leantime\Core\Http\HttpKernel::class);
    $response = $httpKernel->handle($request);
    $body = $response->getContent() ?: '';

    $memPeak = memory_get_peak_usage(true);
    echo 'http_status='.$response->getStatusCode()."\n";
    echo 'mem_peak='.round($memPeak / 1024 / 1024, 1)."MiB\n";
    echo 'http_body_bytes='.strlen($body)."\n";
    echo "status=ok\n";
    $httpKernel->terminate($request, $response);
} catch (Throwable $e) {
    $memPeak = memory_get_peak_usage(true);
    echo 'mem_peak='.round($memPeak / 1024 / 1024, 1)."MiB\n";
    echo 'status=error'."\n";
    echo 'exception='.get_class($e).': '.$e->getMessage()."\n";
    echo $e->getTraceAsString()."\n";
    exit(2);
}
