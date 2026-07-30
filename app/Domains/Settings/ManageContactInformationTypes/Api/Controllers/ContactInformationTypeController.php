<?php

namespace App\Domains\Settings\ManageContactInformationTypes\Api\Controllers;

use App\Http\Controllers\ApiController;
use App\Http\Resources\ContactInformationTypeResource;
use Illuminate\Http\Request;
use Knuckles\Scribe\Attributes\QueryParam;

/**
 * @group Account management
 *
 * @subgroup Contact information types
 */
class ContactInformationTypeController extends ApiController
{
    public function __construct()
    {
        $this->middleware('abilities:read')->only(['index']);

        parent::__construct();
    }

    /**
     * List all contact information types.
     *
     * Get all the contact information types defined in the account.
     */
    #[QueryParam('limit', 'int', description: 'A limit on the number of objects to be returned. Limit can range between 1 and 100, and the default is 10.', required: false, example: 10)]
    public function index(Request $request)
    {
        $types = $request->user()->account
            ->contactInformationTypes()
            ->orderBy('id')
            ->paginate($this->getLimitPerPage());

        return ContactInformationTypeResource::collection($types);
    }
}
