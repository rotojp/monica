<?php

namespace App\Domains\Contact\ManageContact\Api\Controllers;

use App\Http\Controllers\ApiController;
use App\Http\Resources\ContactResource;
use App\Models\Contact;
use Illuminate\Http\Request;
use Knuckles\Scribe\Attributes\{QueryParam,ResponseFromApiResource};

/**
 * @group Contact management
 *
 * @subgroup Contacts
 */
class ContactController extends ApiController
{
    /**
     * Relations needed to render a contact with its details.
     *
     * @var array<int, string>
     */
    public const EAGER_LOADS = [
        'contactInformations.contactInformationType',
        'importantDates.contactImportantDateType',
        'addresses.addressType',
        'company',
        'file',
    ];

    public function __construct()
    {
        $this->middleware('abilities:read')->only(['index', 'show']);

        parent::__construct();
    }

    /**
     * List all contacts in a vault.
     *
     * Get all the listed (non-archived) contacts of the given vault, with
     * their contact information, addresses and important dates included.
     */
    #[QueryParam('limit', 'int', description: 'A limit on the number of objects to be returned. Limit can range between 1 and 100, and the default is 10.', required: false, example: 10)]
    #[ResponseFromApiResource(ContactResource::class, Contact::class, collection: true)]
    public function index(Request $request, string $vaultId)
    {
        $vault = $request->user()->account->vaults()
            ->findOrFail($vaultId);

        $contacts = $vault->contacts()
            ->active()
            ->with(self::EAGER_LOADS)
            ->orderBy('last_name')
            ->orderBy('first_name')
            ->paginate($this->getLimitPerPage());

        return ContactResource::collection($contacts);
    }

    /**
     * Retrieve a contact.
     *
     * Get a specific contact object with its contact information, addresses
     * and important dates included.
     */
    #[ResponseFromApiResource(ContactResource::class, Contact::class)]
    public function show(Request $request, string $vaultId, string $contactId)
    {
        $vault = $request->user()->account->vaults()
            ->findOrFail($vaultId);

        $contact = $vault->contacts()
            ->with(self::EAGER_LOADS)
            ->findOrFail($contactId);

        return new ContactResource($contact);
    }
}
