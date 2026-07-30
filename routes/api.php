<?php

use App\Domains\Contact\ManageCalls\Api\Controllers\ContactCallController;
use App\Domains\Contact\ManageContact\Api\Controllers\ContactController;
use App\Domains\Contact\ManageContactInformation\Api\Controllers\ContactInformationController;
use App\Domains\Contact\ManageReminders\Api\Controllers\ContactReminderController;
use App\Domains\Contact\ManageTasks\Api\Controllers\ContactTaskController;
use App\Domains\Settings\ManageContactInformationTypes\Api\Controllers\ContactInformationTypeController;
use App\Domains\Settings\ManageUsers\Api\Controllers\UserController;
use App\Domains\Vault\ManageVault\Api\Controllers\VaultController;
use Illuminate\Support\Facades\Route;

/*
|--------------------------------------------------------------------------
| API Routes
|--------------------------------------------------------------------------
|
| Here is where you can register API routes for your application. These
| routes are loaded by the bootstrap/app.php file and all of them will
| be assigned to the "api" middleware group. Make something great!
|
*/

Route::middleware('auth:sanctum')->name('api.')->group(function () {
    // users
    Route::get('user', [UserController::class, 'user']);
    Route::apiResource('users', UserController::class)->only(['index', 'show']);

    // vaults
    Route::apiResource('vaults', VaultController::class);

    // contacts
    Route::apiResource('vaults.contacts', ContactController::class)->only(['index', 'show']);

    // tasks
    Route::get('vaults/{vault}/tasks', [ContactTaskController::class, 'index'])->name('vaults.tasks.index');
    Route::put('vaults/{vault}/tasks/{task}/toggle', [ContactTaskController::class, 'toggle'])->name('vaults.tasks.toggle');
    Route::post('vaults/{vault}/contacts/{contact}/tasks', [ContactTaskController::class, 'store'])->name('vaults.contacts.tasks.store');

    // reminders
    Route::get('vaults/{vault}/reminders', [ContactReminderController::class, 'index'])->name('vaults.reminders.index');

    // calls
    Route::get('vaults/{vault}/contacts/{contact}/calls', [ContactCallController::class, 'index'])->name('vaults.contacts.calls.index');
    Route::post('vaults/{vault}/contacts/{contact}/calls', [ContactCallController::class, 'store'])->name('vaults.contacts.calls.store');

    // contact information
    Route::get('contactInformationTypes', [ContactInformationTypeController::class, 'index'])->name('contactinformationtypes.index');
    Route::post('vaults/{vault}/contacts/{contact}/contactInformation', [ContactInformationController::class, 'store'])->name('vaults.contacts.information.store');
    Route::delete('vaults/{vault}/contacts/{contact}/contactInformation/{information}', [ContactInformationController::class, 'destroy'])->name('vaults.contacts.information.destroy');
});
