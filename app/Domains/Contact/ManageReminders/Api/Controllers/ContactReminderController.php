<?php

namespace App\Domains\Contact\ManageReminders\Api\Controllers;

use App\Http\Controllers\ApiController;
use App\Http\Resources\ContactReminderResource;
use App\Models\ContactReminder;
use Illuminate\Http\Request;
use Knuckles\Scribe\Attributes\{QueryParam,ResponseFromApiResource};

/**
 * @group Contact management
 *
 * @subgroup Reminders
 */
class ContactReminderController extends ApiController
{
    public function __construct()
    {
        $this->middleware('abilities:read')->only(['index']);

        parent::__construct();
    }

    /**
     * List all reminders in a vault.
     *
     * Get all the reminders of all the contacts in the given vault.
     */
    #[QueryParam('limit', 'int', description: 'A limit on the number of objects to be returned. Limit can range between 1 and 100, and the default is 10.', required: false, example: 10)]
    #[ResponseFromApiResource(ContactReminderResource::class, ContactReminder::class, collection: true)]
    public function index(Request $request, string $vaultId)
    {
        $vault = $request->user()->account->vaults()
            ->findOrFail($vaultId);

        $reminders = ContactReminder::whereHas('contact', function ($query) use ($vault) {
            $query->where('vault_id', $vault->id);
        })
            ->with('contact')
            ->orderBy('id')
            ->paginate($this->getLimitPerPage());

        return ContactReminderResource::collection($reminders);
    }
}
