<?php

namespace App\Domains\Contact\ManageTasks\Api\Controllers;

use App\Domains\Contact\ManageTasks\Services\CreateContactTask;
use App\Domains\Contact\ManageTasks\Services\ToggleContactTask;
use App\Http\Controllers\ApiController;
use App\Http\Resources\ContactTaskResource;
use App\Models\ContactTask;
use Illuminate\Http\Request;
use Knuckles\Scribe\Attributes\{BodyParam,QueryParam,ResponseFromApiResource};

/**
 * @group Contact management
 *
 * @subgroup Tasks
 */
class ContactTaskController extends ApiController
{
    public function __construct()
    {
        $this->middleware('abilities:read')->only(['index']);
        $this->middleware('abilities:write')->only(['store', 'toggle']);

        parent::__construct();
    }

    /**
     * List all tasks in a vault.
     *
     * Get all the tasks of all the contacts in the given vault.
     */
    #[QueryParam('limit', 'int', description: 'A limit on the number of objects to be returned. Limit can range between 1 and 100, and the default is 10.', required: false, example: 10)]
    #[ResponseFromApiResource(ContactTaskResource::class, ContactTask::class, collection: true)]
    public function index(Request $request, string $vaultId)
    {
        $vault = $request->user()->account->vaults()
            ->findOrFail($vaultId);

        $tasks = ContactTask::whereHas('contact', function ($query) use ($vault) {
            $query->where('vault_id', $vault->id);
        })
            ->with('contact')
            ->orderBy('id')
            ->paginate($this->getLimitPerPage());

        return ContactTaskResource::collection($tasks);
    }

    /**
     * Create a task.
     *
     * Creates a task for the given contact.
     */
    #[BodyParam('label', description: 'The title of the task. Max 255 characters.')]
    #[BodyParam('description', description: 'The description of the task. Max 65535 characters.', required: false)]
    #[BodyParam('due_at', description: 'The due date of the task, in the Y-m-d format.', required: false)]
    #[ResponseFromApiResource(ContactTaskResource::class, ContactTask::class, status: 201)]
    public function store(Request $request, string $vaultId, string $contactId)
    {
        $task = (new CreateContactTask)->execute([
            'account_id' => $request->user()->account_id,
            'author_id' => $request->user()->id,
            'vault_id' => $vaultId,
            'contact_id' => $contactId,
            'label' => $request->input('label'),
            'description' => $request->input('description'),
            'due_at' => $request->input('due_at'),
        ]);

        return new ContactTaskResource($task->load('contact'));
    }

    /**
     * Toggle a task.
     *
     * Flips the completion state of the given task.
     */
    #[ResponseFromApiResource(ContactTaskResource::class, ContactTask::class)]
    public function toggle(Request $request, string $vaultId, int $taskId)
    {
        $vault = $request->user()->account->vaults()
            ->findOrFail($vaultId);

        $task = ContactTask::whereHas('contact', function ($query) use ($vault) {
            $query->where('vault_id', $vault->id);
        })->findOrFail($taskId);

        $task = (new ToggleContactTask)->execute([
            'account_id' => $request->user()->account_id,
            'author_id' => $request->user()->id,
            'vault_id' => $vaultId,
            'contact_id' => $task->contact_id,
            'contact_task_id' => $task->id,
        ]);

        return new ContactTaskResource($task->load('contact'));
    }
}
